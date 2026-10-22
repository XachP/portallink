// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AttesterSet
/// @notice M-of-N ECDSA committee (default 2-of-3) with EIP-712 domain separation and
///         self-governed rotation: only the current committee can replace itself.
abstract contract AttesterSet {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("PortalLink");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 public constant ROTATE_TYPEHASH =
        keccak256("Rotate(address[] attesters,uint8 threshold,uint64 epoch)");

    /// secp256k1n / 2, rejects malleable signatures
    uint256 private constant HALF_N = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
    uint256 public constant MAX_ATTESTERS = 16;

    address[] private _attesters;
    mapping(address => bool) public isAttester;
    uint8 public threshold;
    /// @notice Increments on every rotation; old-epoch rotation signatures cannot be replayed.
    uint64 public epoch;

    event AttestersRotated(uint64 indexed epoch, address[] attesters, uint8 threshold);

    error BadThreshold();
    error BadAttester();
    error NotEnoughSignatures();
    error BadSignature();
    error SignersNotSorted();
    error UnknownSigner(address signer);

    function _initAttesters(address[] memory attesters_, uint8 threshold_) internal {
        _setAttesters(attesters_, threshold_);
    }

    function attesters() external view returns (address[] memory) {
        return _attesters;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function hashTypedData(bytes32 structHash) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @notice Rotate the committee. Must be signed by `threshold` members of the CURRENT set.
    function rotateAttesters(address[] calldata newAttesters, uint8 newThreshold, bytes[] calldata sigs) external {
        bytes32 structHash = keccak256(
            abi.encode(ROTATE_TYPEHASH, keccak256(abi.encodePacked(newAttesters)), newThreshold, epoch)
        );
        _verify(hashTypedData(structHash), sigs);
        unchecked { ++epoch; }
        _setAttesters(newAttesters, newThreshold);
    }

    /// @dev Signatures must be 65-byte (r,s,v), from distinct attesters, sorted by ascending
    ///      signer address (cheap duplicate check). Extra signatures beyond threshold are ignored.
    function _verify(bytes32 digest, bytes[] calldata sigs) internal view {
        uint256 t = threshold;
        if (sigs.length < t) revert NotEnoughSignatures();
        address last;
        for (uint256 i; i < t; ++i) {
            address s = _recover(digest, sigs[i]);
            if (s <= last) revert SignersNotSorted();
            if (!isAttester[s]) revert UnknownSigner(s);
            last = s;
        }
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address signer) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (uint256(s) > HALF_N || (v != 27 && v != 28)) revert BadSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
    }

    function _setAttesters(address[] memory list, uint8 t) private {
        uint256 n = list.length;
        if (n == 0 || n > MAX_ATTESTERS || t == 0 || t > n || t <= n / 2) revert BadThreshold();
        for (uint256 i; i < _attesters.length; ++i) isAttester[_attesters[i]] = false;
        delete _attesters;
        for (uint256 i; i < n; ++i) {
            address a = list[i];
            if (a == address(0) || isAttester[a]) revert BadAttester();
            isAttester[a] = true;
            _attesters.push(a);
        }
        threshold = t;
        emit AttestersRotated(epoch, list, t);
    }
}
