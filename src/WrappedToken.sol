// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title WrappedToken
/// @notice Minimal ERC-20 that represents a remote chain's native coin (e.g. wPOT on Mezo,
///         wBTC.m on Portaldot). Only the bound PortalGateway can mint or burn.
/// @dev Kept deliberately small: pallet-revive charges a storage deposit per byte of code.
contract WrappedToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    /// @notice Chain id whose native coin this token represents.
    uint64 public immutable originChainId;
    /// @notice The only account allowed to mint/burn. Bound once, then immutable in practice.
    address public gateway;
    address private immutable deployer;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event GatewayBound(address indexed gateway);

    error NotGateway();
    error AlreadyBound();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    constructor(string memory name_, string memory symbol_, uint64 originChainId_) {
        name = name_;
        symbol = symbol_;
        originChainId = originChainId_;
        deployer = msg.sender;
    }

    /// @notice One-shot binding of the gateway (breaks the deploy-order cycle without CREATE,
    ///         which keeps deployment identical on revive and on standard EVMs).
    function bindGateway(address gateway_) external {
        if (msg.sender != deployer) revert NotGateway();
        if (gateway != address(0)) revert AlreadyBound();
        if (gateway_ == address(0)) revert ZeroAddress();
        gateway = gateway_;
        emit GatewayBound(gateway_);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < value) revert InsufficientAllowance();
            unchecked { allowance[from][msg.sender] = a - value; }
        }
        _move(from, to, value);
        return true;
    }

    function mint(address to, uint256 value) external {
        if (msg.sender != gateway) revert NotGateway();
        if (to == address(0)) revert ZeroAddress();
        totalSupply += value;
        unchecked { balanceOf[to] += value; }
        emit Transfer(address(0), to, value);
    }

    /// @notice Gateway burns `value` from `from`. The gateway only calls this for msg.sender of
    ///         its own `burn`, so no allowance is needed.
    function burnFrom(address from, uint256 value) external {
        if (msg.sender != gateway) revert NotGateway();
        uint256 b = balanceOf[from];
        if (b < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = b - value;
            totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }

    function _move(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 b = balanceOf[from];
        if (b < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = b - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
