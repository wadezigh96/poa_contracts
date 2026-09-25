// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {POAAgentFinance} from "../contracts/POAAgentFinance.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
}

contract MockToken {
    mapping(address => uint256) public balanceOf;
    bool public shouldFail;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFail(bool value) external {
        shouldFail = value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (shouldFail || balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ReentrantTarget {
    POAAgentFinance internal poa;
    bool public attempted;

    constructor(address _poa) {
        poa = POAAgentFinance(_poa);
    }

    function attack() external payable {
        attempted = true;
        (bool ok,) = address(poa).call(
            abi.encodeWithSelector(
                poa.execute.selector,
                address(this), 0, abi.encodeWithSelector(this.attack.selector)
            )
        );
        require(!ok, "reentrancy succeeded");
    }
}

contract POAAgentFinanceSecurityTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    POAAgentFinance internal poa;
    MockToken internal token;
    ReentrantTarget internal target;

    address internal constant OWNER = address(0x1001);
    address internal constant AGENT = address(0x1002);
    address internal constant RECIPIENT = address(0x1003);
    address internal constant NEW_OWNER = address(0x2001);

    function setUp() public {
        poa = new POAAgentFinance(OWNER);
        token = new MockToken();
        target = new ReentrantTarget(address(poa));
    }

    function configureAgent(uint256 cap, uint256 txLimit, uint256 duration) internal {
        vm.prank(OWNER);
        poa.configureAgent(AGENT, uint64(block.timestamp + duration), cap, txLimit);
    }

    function allowPing() internal {
        vm.prank(OWNER);
        poa.setCallPermission(AGENT, address(target), ReentrantTarget.attack.selector, true);
    }

    function fund(uint256 amount) internal {
        (bool ok,) = address(poa).call{value: amount}("");
        require(ok, "funding failed");
    }

    function testOwnerIsSet() public view {
        require(poa.owner() == OWNER, "owner");
    }

    function testAgentCannotExceedNativeTxLimit() public {
        configureAgent(10 ether, 1 ether, 1 days);
        allowPing();
        fund(2 ether);

        vm.prank(AGENT);
        (bool ok,) = address(poa).call(
            abi.encodeWithSelector(
                poa.execute.selector,
                address(target), 2 ether, abi.encodeWithSelector(target.attack.selector)
            )
        );
        require(!ok, "tx limit bypass");
    }

    function testAgentCanSpendWithinLimit() public {
        configureAgent(2 ether, 1 ether, 1 days);
        allowPing();
        fund(1 ether);

        vm.prank(AGENT);
        poa.execute(address(target), 1 ether, abi.encodeWithSelector(target.attack.selector));
        require(target.attempted(), "execution failed");
    }

    function testExpiryFailsClosed() public {
        configureAgent(10 ether, 1 ether, 1 days);
        allowPing();
        fund(1 ether);

        vm.warp(block.timestamp + 1 days);
        vm.prank(AGENT);
        (bool ok,) = address(poa).call(
            abi.encodeWithSelector(
                poa.execute.selector,
                address(target), 1 ether, abi.encodeWithSelector(target.attack.selector)
            )
        );
        require(!ok, "expired agent executed");
        require(poa.agentRemainingNative(AGENT) == 0, "expired allowance remains");
    }

    function testRevokeBlocksAgent() public {
        configureAgent(10 ether, 1 ether, 1 days);
        allowPing();
        fund(1 ether);

        vm.prank(OWNER);
        poa.revokeAgent(AGENT);

        vm.prank(AGENT);
        (bool ok,) = address(poa).call(
            abi.encodeWithSelector(
                poa.execute.selector,
                address(target), 1 ether, abi.encodeWithSelector(target.attack.selector)
            )
        );
        require(!ok, "revoked agent executed");
    }

    function testUnauthorizedRecipientBlocked() public {
        configureAgent(0, 0, 1 days);
        vm.prank(OWNER);
        poa.setTokenPolicy(AGENT, address(token), 100, 100);
        token.mint(address(poa), 100);

        vm.prank(AGENT);
        (bool ok,) = address(poa).call(
            abi.encodeWithSelector(poa.transferToken.selector, address(token), RECIPIENT, 1)
        );
        require(!ok, "recipient bypass");
    }

    function testUnauthorizedSelectorBlocked() public {
        configureAgent(10 ether, 10 ether, 1 days);
        fund(1 ether);

        vm.prank(AGENT);
        (bool ok,) = address(poa).call(
            abi.encodeWithSelector(
                poa.execute.selector,
                address(target), 1 ether, abi.encodeWithSelector(target.attack.selector)
            )
        );
        require(!ok, "selector bypass");
    }

    function testTokenTxLimitBlocked() public {
        configureAgent(0, 0, 1 days);
        vm.prank(OWNER);
        poa.setRecipientPermission(AGENT, RECIPIENT, true);
        vm.prank(OWNER);
        poa.setTokenPolicy(AGENT, address(token), 100, 10);
        token.mint(address(poa), 100);

        vm.prank(AGENT);
        (bool ok,) = address(poa).call(
            abi.encodeWithSelector(poa.transferToken.selector, address(token), RECIPIENT, 11)
        );
        require(!ok, "token tx limit bypass");
    }

    function testPauseBlocksAgentExecution() public {
        configureAgent(10 ether, 1 ether, 1 days);
        allowPing();
        fund(1 ether);
        vm.prank(OWNER);
        poa.setPaused(true);

        vm.prank(AGENT);
        (bool ok,) = address(poa).call(
            abi.encodeWithSelector(
                poa.execute.selector,
                address(target), 1 ether, abi.encodeWithSelector(target.attack.selector)
            )
        );
        require(!ok, "pause bypass");
    }

    function testTwoStepOwnershipRejectsWrongCaller() public {
        vm.prank(OWNER);
        poa.transferOwnership(NEW_OWNER);
        (bool ok,) = address(poa).call(abi.encodeWithSelector(poa.acceptOwnership.selector));
        require(!ok, "ownership bypass");
        require(poa.owner() == OWNER, "owner changed");
    }

    function testTwoStepOwnershipAcceptsPendingOwner() public {
        vm.prank(OWNER);
        poa.transferOwnership(NEW_OWNER);
        vm.prank(NEW_OWNER);
        poa.acceptOwnership();
        require(poa.owner() == NEW_OWNER, "ownership not accepted");
    }

    function testReentrancyBlocked() public {
        configureAgent(10 ether, 1 ether, 1 days);
        allowPing();
        fund(1 ether);

        vm.prank(AGENT);
        poa.execute(address(target), 1 ether, abi.encodeWithSelector(target.attack.selector));
        require(target.attempted(), "attack did not run");
    }

    receive() external payable {}
}
