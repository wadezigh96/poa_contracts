// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title POA Agent Finance
/// @notice Human-controlled spending authority for autonomous/AI finance agents.
/// @dev V1 intentionally limits agent execution to owner-approved target + selector
///      pairs and explicit native/ERC20 spending caps. No private key is held by the AI.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract POAAgentFinance {
    struct AgentPolicy {
        bool active;
        uint64 expiresAt;
        uint256 nativeCap;
        uint256 nativeSpent;
    }

    struct TokenPolicy {
        uint256 cap;
        uint256 spent;
    }

    address public owner;
    bool public paused;

    mapping(address => AgentPolicy) public agents;
    mapping(address => mapping(address => mapping(bytes4 => bool))) public allowedCalls;
    mapping(address => mapping(address => TokenPolicy)) public tokenPolicies;
    mapping(address => mapping(address => bool)) public allowedRecipients;

    uint256 public nonce;

    error NotOwner();
    error NotAgent();
    error Paused();
    error InvalidAgent();
    error Expired();
    error CapExceeded();
    error TargetNotAllowed();
    error RecipientNotAllowed();
    error InvalidCallData();
    error CallFailed(bytes reason);
    error TransferFailed();
    error InvalidOwner();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event AgentConfigured(address indexed agent, uint64 expiresAt, uint256 nativeCap);
    event AgentRevoked(address indexed agent);
    event CallPermissionSet(address indexed agent, address indexed target, bytes4 indexed selector, bool allowed);
    event RecipientPermissionSet(address indexed agent, address indexed recipient, bool allowed);
    event TokenPolicySet(address indexed agent, address indexed token, uint256 cap);
    event NativeDeposited(address indexed from, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);
    event AgentCall(address indexed agent, address indexed target, uint256 value, bytes4 selector, uint256 nonce);
    event AgentTokenTransfer(address indexed agent, address indexed token, address indexed recipient, uint256 amount, uint256 nonce);
    event PausedSet(bool paused);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier onlyActiveAgent() {
        AgentPolicy memory p = agents[msg.sender];
        if (!p.active) revert NotAgent();
        if (p.expiresAt != 0 && block.timestamp > p.expiresAt) revert Expired();
        if (paused) revert Paused();
        _;
    }

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert InvalidOwner();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    receive() external payable {
        emit NativeDeposited(msg.sender, msg.value);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedSet(value);
    }

    function configureAgent(address agent, uint64 expiresAt, uint256 nativeCap) external onlyOwner {
        if (agent == address(0)) revert InvalidAgent();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert Expired();
        agents[agent] = AgentPolicy({
            active: true,
            expiresAt: expiresAt,
            nativeCap: nativeCap,
            nativeSpent: 0
        });
        emit AgentConfigured(agent, expiresAt, nativeCap);
    }

    function revokeAgent(address agent) external onlyOwner {
        agents[agent].active = false;
        emit AgentRevoked(agent);
    }

    function setCallPermission(address agent, address target, bytes4 selector, bool allowed) external onlyOwner {
        allowedCalls[agent][target][selector] = allowed;
        emit CallPermissionSet(agent, target, selector, allowed);
    }

    function setRecipientPermission(address agent, address recipient, bool allowed) external onlyOwner {
        allowedRecipients[agent][recipient] = allowed;
        emit RecipientPermissionSet(agent, recipient, allowed);
    }

    function setTokenPolicy(address agent, address token, uint256 cap) external onlyOwner {
        tokenPolicies[agent][token].cap = cap;
        emit TokenPolicySet(agent, token, cap);
    }

    function deposit() external payable whenNotPaused {
        emit NativeDeposited(msg.sender, msg.value);
    }

    function withdrawNative(address payable to, uint256 amount) external onlyOwner {
        if (amount > address(this).balance) revert CapExceeded();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert CallFailed("");
        emit NativeWithdrawn(to, amount);
    }

    /// @notice Agent-controlled native execution through an owner-approved target/selector.
    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyActiveAgent
        returns (bytes memory result)
    {
        if (data.length < 4) revert InvalidCallData();
        bytes4 selector;
        assembly {
            selector := calldataload(data.offset)
        }
        if (!allowedCalls[msg.sender][target][selector]) revert TargetNotAllowed();

        AgentPolicy storage p = agents[msg.sender];
        if (p.nativeSpent + value > p.nativeCap) revert CapExceeded();
        if (value > address(this).balance) revert CapExceeded();
        p.nativeSpent += value;

        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed(ret);

        uint256 currentNonce = nonce++;
        emit AgentCall(msg.sender, target, value, selector, currentNonce);
        return ret;
    }

    /// @notice Agent-controlled ERC20 transfer with explicit token and recipient policy.
    function transferToken(address token, address recipient, uint256 amount)
        external
        onlyActiveAgent
    {
        if (!allowedRecipients[msg.sender][recipient]) revert RecipientNotAllowed();
        TokenPolicy storage p = tokenPolicies[msg.sender][token];
        if (p.spent + amount > p.cap) revert CapExceeded();
        p.spent += amount;

        bool ok = IERC20(token).transfer(recipient, amount);
        if (!ok) revert TransferFailed();

        uint256 currentNonce = nonce++;
        emit AgentTokenTransfer(msg.sender, token, recipient, amount, currentNonce);
    }

    function agentRemainingNative(address agent) external view returns (uint256) {
        AgentPolicy memory p = agents[agent];
        if (p.nativeSpent >= p.nativeCap) return 0;
        return p.nativeCap - p.nativeSpent;
    }

    function tokenRemaining(address agent, address token) external view returns (uint256) {
        TokenPolicy memory p = tokenPolicies[agent][token];
        if (p.spent >= p.cap) return 0;
        return p.cap - p.spent;
    }
}
