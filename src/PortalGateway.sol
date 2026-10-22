// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AttesterSet} from "./AttesterSet.sol";
import {WrappedToken} from "./WrappedToken.sol";

/// @title PortalGateway
/// @notice One gateway per chain. It (a) escrows this chain's native coin and releases it when
///         the wrapped copy is burned on a peer chain, and (b) mints/burns wrapped copies of
///         each peer chain's native coin. Every inbound transfer needs `threshold` attester
///         signatures over an EIP-712 message bound to THIS chain id and THIS gateway address.
///
///         Safety rails beyond the committee:
///         - releases of native coin are capped by what was actually locked for that route
///           (a compromised committee cannot drain more than the route's escrow);
///         - per-route inbound rate limit (rolling window) and per-transfer bounds;
///         - guardian can pause instantly; only the admin can unpause;
///         - failed native payouts are parked for pull-withdrawal, so a hostile recipient
///           cannot block the relayer queue.
contract PortalGateway is AttesterSet {
    enum Kind {
        NativeLocked, // source escrowed its native coin -> destination mints wrapped
        WrappedBurned // source burned wrapped copy of destination's native -> destination releases
    }

    struct Transfer {
        uint64 srcChainId;
        uint64 dstChainId;
        uint64 nonce;
        Kind kind;
        address sender;
        address recipient;
        uint256 amount;
    }

    /// @notice Bounds + rolling inbound window for ONE asset on a route. Each route carries two:
    ///         `native` (this chain's coin: outbound locks, inbound releases) and `wrapped`
    ///         (the peer's coin: outbound burns, inbound mints). Values differ by orders of
    ///         magnitude (tPOT vs BTC), so they are never mixed.
    struct Limits {
        uint128 minAmount;
        uint128 maxAmount;
        uint128 windowCap;
        uint128 windowUsed;
        uint64 windowStart;
    }

    struct Route {
        address peer; // gateway on the remote chain
        WrappedToken wrapped; // local wrapped copy of the remote chain's native coin
        uint256 lockedOut; // native escrowed here for this route (outbound, not yet returned)
        Limits native;
        Limits wrappedLimits;
    }

    bytes32 public constant TRANSFER_TYPEHASH = keccak256(
        "Transfer(uint64 srcChainId,uint64 dstChainId,uint64 nonce,uint8 kind,address sender,address recipient,uint256 amount)"
    );
    uint64 public constant WINDOW = 1 days;

    address public admin;
    address public pendingAdmin;
    address public guardian;
    bool public paused;
    uint64 public outboundNonce;

    mapping(uint64 => Route) private _routes;
    uint64[] private _routeIds;
    /// @notice transfer id (EIP-712 struct hash, identical on both chains) => processed
    mapping(bytes32 => bool) public processed;
    /// @notice native owed to recipients whose payout call reverted
    mapping(address => uint256) public owed;
    uint256 public totalOwed;
    bool private _entered;

    event TransferSent(
        bytes32 indexed id,
        uint64 indexed dstChainId,
        uint64 nonce,
        Kind kind,
        address indexed sender,
        address recipient,
        uint256 amount
    );
    event TransferReceived(
        bytes32 indexed id, uint64 indexed srcChainId, uint64 nonce, Kind kind, address indexed recipient, uint256 amount
    );
    event PayoutDeferred(address indexed recipient, uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);
    event RouteConfigured(uint64 indexed chainId, address peer, address wrapped);
    event LimitsSet(uint64 indexed chainId, bool indexed wrappedAsset, uint128 minAmount, uint128 maxAmount, uint128 windowCap);
    event Paused(address by);
    event Unpaused(address by);
    event AdminProposed(address indexed admin);
    event AdminAccepted(address indexed admin);
    event GuardianSet(address indexed guardian);

    error NotAdmin();
    error NotGuardian();
    error IsPaused();
    error UnknownRoute(uint64 chainId);
    error AmountOutOfBounds();
    error WrongDestination();
    error AlreadyProcessed(bytes32 id);
    error RateLimited();
    error EscrowShortfall();
    error ZeroAddress();
    error Reentrancy();
    error NothingOwed();
    error PayoutFailed();
    error RouteExists();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address admin_, address guardian_, address[] memory attesters_, uint8 threshold_) {
        if (admin_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        admin = admin_;
        guardian = guardian_;
        _initAttesters(attesters_, threshold_);
    }

    // ----------------------------------------------------------------------------- outbound

    /// @notice Escrow native coin here; attesters mint the wrapped copy on `dstChainId`.
    function lockNative(uint64 dstChainId, address recipient) external payable whenNotPaused returns (bytes32 id) {
        Route storage r = _route(dstChainId);
        _checkBounds(r.native, msg.value);
        if (recipient == address(0)) revert ZeroAddress();
        r.lockedOut += msg.value;
        id = _emitSent(dstChainId, Kind.NativeLocked, recipient, msg.value);
    }

    /// @notice Burn the wrapped copy of `dstChainId`'s native coin; attesters release it there.
    function burnWrapped(uint64 dstChainId, address recipient, uint256 amount)
        external
        whenNotPaused
        returns (bytes32 id)
    {
        Route storage r = _route(dstChainId);
        _checkBounds(r.wrappedLimits, amount);
        if (recipient == address(0)) revert ZeroAddress();
        r.wrapped.burnFrom(msg.sender, amount);
        id = _emitSent(dstChainId, Kind.WrappedBurned, recipient, amount);
    }

    // ------------------------------------------------------------------------------ inbound

    /// @notice Execute an attested transfer from a peer chain. Anyone may relay it.
    function receiveTransfer(Transfer calldata t, bytes[] calldata sigs) external nonReentrant whenNotPaused {
        if (t.dstChainId != block.chainid) revert WrongDestination();
        if (t.recipient == address(0)) revert ZeroAddress();
        Route storage r = _route(t.srcChainId);
        bytes32 id = transferId(t);
        if (processed[id]) revert AlreadyProcessed(id);
        _verify(hashTypedData(id), sigs);
        processed[id] = true;
        _consumeWindow(t.kind == Kind.NativeLocked ? r.wrappedLimits : r.native, t.amount);

        emit TransferReceived(id, t.srcChainId, t.nonce, t.kind, t.recipient, t.amount);

        if (t.kind == Kind.NativeLocked) {
            r.wrapped.mint(t.recipient, t.amount);
        } else {
            if (t.amount > r.lockedOut) revert EscrowShortfall();
            r.lockedOut -= t.amount;
            if (!_pushNative(t.recipient, t.amount)) {
                owed[t.recipient] += t.amount;
                totalOwed += t.amount;
                emit PayoutDeferred(t.recipient, t.amount);
            }
        }
    }

    /// @notice Pull a payout that could not be pushed (e.g. recipient contract reverted).
    function withdrawOwed() external nonReentrant {
        uint256 amt = owed[msg.sender];
        if (amt == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        totalOwed -= amt;
        emit Withdrawn(msg.sender, amt);
        (bool ok,) = msg.sender.call{value: amt}("");
        if (!ok) revert PayoutFailed();
    }

    // -------------------------------------------------------------------------------- views

    /// @notice Chain-independent id: the EIP-712 struct hash. Same value on source and destination.
    function transferId(Transfer calldata t) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TRANSFER_TYPEHASH, t.srcChainId, t.dstChainId, t.nonce, uint8(t.kind), t.sender, t.recipient, t.amount
            )
        );
    }

    /// @notice Digest attesters sign for a transfer delivered to THIS gateway.
    function transferDigest(Transfer calldata t) external view returns (bytes32) {
        return hashTypedData(transferId(t));
    }

    function routeIds() external view returns (uint64[] memory) {
        return _routeIds;
    }

    function route(uint64 chainId) external view returns (address peer, address wrapped, uint256 lockedOut) {
        Route storage r = _routes[chainId];
        return (r.peer, address(r.wrapped), r.lockedOut);
    }

    function limits(uint64 chainId, bool wrappedAsset) external view returns (Limits memory) {
        Route storage r = _routes[chainId];
        return wrappedAsset ? r.wrappedLimits : r.native;
    }

    /// @notice Remaining inbound capacity in the current window. `wrappedAsset` = true for
    ///         mints of the peer's coin, false for releases of this chain's coin.
    function windowRemaining(uint64 chainId, bool wrappedAsset) external view returns (uint256) {
        Route storage r = _routes[chainId];
        Limits storage l = wrappedAsset ? r.wrappedLimits : r.native;
        if (block.timestamp >= uint256(l.windowStart) + WINDOW) return l.windowCap;
        return l.windowCap - l.windowUsed;
    }

    // -------------------------------------------------------------------------------- admin

    struct LimitConfig {
        uint128 minAmount;
        uint128 maxAmount;
        uint128 windowCap;
    }

    function configureRoute(
        uint64 chainId,
        address peer,
        WrappedToken wrapped,
        LimitConfig calldata nativeCfg,
        LimitConfig calldata wrappedCfg
    ) external onlyAdmin {
        if (peer == address(0) || address(wrapped) == address(0)) revert ZeroAddress();
        Route storage r = _routes[chainId];
        if (r.peer != address(0)) revert RouteExists(); // peers are write-once
        r.peer = peer;
        r.wrapped = wrapped;
        _routeIds.push(chainId);
        emit RouteConfigured(chainId, peer, address(wrapped));
        _setLimits(r.native, chainId, false, nativeCfg);
        _setLimits(r.wrappedLimits, chainId, true, wrappedCfg);
    }

    function setLimits(uint64 chainId, bool wrappedAsset, LimitConfig calldata cfg) external onlyAdmin {
        Route storage r = _route(chainId);
        _setLimits(wrappedAsset ? r.wrappedLimits : r.native, chainId, wrappedAsset, cfg);
    }

    function pause() external {
        if (msg.sender != guardian && msg.sender != admin) revert NotGuardian();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setGuardian(address g) external onlyAdmin {
        if (g == address(0)) revert ZeroAddress();
        guardian = g;
        emit GuardianSet(g);
    }

    function proposeAdmin(address a) external onlyAdmin {
        pendingAdmin = a;
        emit AdminProposed(a);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminAccepted(msg.sender);
    }

    // ------------------------------------------------------------------------------ internal

    /// @dev Gas-capped push that never copies return data (no return-bomb).
    function _pushNative(address to, uint256 amount) private returns (bool ok) {
        assembly {
            ok := call(50000, to, amount, 0, 0, 0, 0)
        }
    }

    function _route(uint64 chainId) private view returns (Route storage r) {
        r = _routes[chainId];
        if (r.peer == address(0)) revert UnknownRoute(chainId);
    }

    function _checkBounds(Limits storage l, uint256 amount) private view {
        if (amount < l.minAmount || amount > l.maxAmount) revert AmountOutOfBounds();
    }

    function _consumeWindow(Limits storage r, uint256 amount) private {
        if (block.timestamp >= uint256(r.windowStart) + WINDOW) {
            r.windowStart = uint64(block.timestamp);
            r.windowUsed = 0;
        }
        uint256 used = uint256(r.windowUsed) + amount;
        if (used > r.windowCap) revert RateLimited();
        r.windowUsed = uint128(used);
    }

    function _setLimits(Limits storage l, uint64 chainId, bool wrappedAsset, LimitConfig calldata c) private {
        if (c.minAmount == 0 || c.minAmount > c.maxAmount || c.maxAmount > c.windowCap) revert AmountOutOfBounds();
        l.minAmount = c.minAmount;
        l.maxAmount = c.maxAmount;
        l.windowCap = c.windowCap;
        emit LimitsSet(chainId, wrappedAsset, c.minAmount, c.maxAmount, c.windowCap);
    }

    function _emitSent(uint64 dstChainId, Kind kind, address recipient, uint256 amount) private returns (bytes32 id) {
        uint64 nonce = ++outboundNonce;
        id = keccak256(
            abi.encode(
                TRANSFER_TYPEHASH, uint64(block.chainid), dstChainId, nonce, uint8(kind), msg.sender, recipient, amount
            )
        );
        emit TransferSent(id, dstChainId, nonce, kind, msg.sender, recipient, amount);
    }
}
