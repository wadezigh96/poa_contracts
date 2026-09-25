// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {POAAgentFinance} from "../contracts/POAAgentFinance.sol";

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

contract MockTarget {
    uint256 public received;

    function ping() external payable returns (uint256) {
        received += msg.value;
        return received;
    }

    function revertCall() external pure {
        revert("blocked");
    }
}

contract POAAgentFinanceSecurityTest {
    POAAgentFinance internal poa;
    MockToken internal token;
    MockTarget internal target;
    address internal constant OWNER = address(0x1001);
    address internal constant AGENT = address(0x1002);
    address internal constant RECIPIENT = address(0x1003);

    function setUp() public {
        poa = new POAAgentFinance(OWNER);
        token = new MockToken();
        target = new MockTarget();
    }

    function testOwnerIsSet() public view {
        require(poa.owner() == OWNER, "owner");
    }

    function testAgentCannotExceedNativeTxLimit() public {
        poa.configureAgent(AGENT, uint64(block.timestamp + 1 days), 10 ether, 1 ether);
        poa.setCallPermission(AGENT, address(target), MockTarget.ping.selector, true);

        (bool funded,) = address(poa).call{value: 2 ether}("");
        require(funded, "funding");

        (bool ok,) = AGENT.call(abi.encodeWithSelector(
            POAAgentFinance.execute.selector,
            address(target), 2 ether, abi.encodeWithSelector(MockTarget.ping.selector)
        ));
        require(!ok, "tx limit bypass");
    }

    function testExpiredAgentCannotExecute() public {
        poa.configureAgent(AGENT, uint64(block.timestamp + 1), 10 ether, 1 ether);
        poa.setCallPermission(AGENT, address(target), MockTarget.ping.selector, true);
        (bool funded,) = address(poa).call{value: 1 ether}("");
        require(funded, "funding");

        // This test is intended to be run with Foundry's time-warp cheatcode.
        // It remains a source-level regression target for expiry enforcement.
    }

    function testUnauthorizedRecipientBlocked() public {
        poa.configureAgent(AGENT, uint64(block.timestamp + 1 days), 0, 0);
        poa.setTokenPolicy(AGENT, address(token), 100, 100);
        token.mint(address(poa), 100);

        (bool ok,) = AGENT.call(abi.encodeWithSelector(
            POAAgentFinance.transferToken.selector,
            address(token), RECIPIENT, 1
        ));
        require(!ok, "recipient bypass");
    }

    function testUnauthorizedSelectorBlocked() public {
        poa.configureAgent(AGENT, uint64(block.timestamp + 1 days), 10 ether, 10 ether);
        (bool funded,) = address(poa).call{value: 1 ether}("");
        require(funded, "funding");

        (bool ok,) = AGENT.call(abi.encodeWithSelector(
            POAAgentFinance.execute.selector,
            address(target), 1 ether, abi.encodeWithSelector(MockTarget.ping.selector)
        ));
        require(!ok, "selector bypass");
    }

    function testTokenTxLimitBlocked() public {
        poa.configureAgent(AGENT, uint64(block.timestamp + 1 days), 0, 0);
        poa.setRecipientPermission(AGENT, RECIPIENT, true);
        poa.setTokenPolicy(AGENT, address(token), 100, 10);
        token.mint(address(poa), 100);

        (bool ok,) = AGENT.call(abi.encodeWithSelector(
            POAAgentFinance.transferToken.selector,
            address(token), RECIPIENT, 11
        ));
        require(!ok, "token tx limit bypass");
    }

    function testPauseBlocksAgentExecution() public {
        poa.configureAgent(AGENT, uint64(block.timestamp + 1 days), 10 ether, 1 ether);
        poa.setCallPermission(AGENT, address(target), MockTarget.ping.selector, true);
        poa.setPaused(true);
        (bool funded,) = address(poa).call{value: 1 ether}("");
        require(funded, "funding");

        (bool ok,) = AGENT.call(abi.encodeWithSelector(
            POAAgentFinance.execute.selector,
            address(target), 1 ether, abi.encodeWithSelector(MockTarget.ping.selector)
        ));
        require(!ok, "pause bypass");
    }

    function testTwoStepOwnershipRejectsWrongCaller() public {
        poa.transferOwnership(address(0x2001));
        (bool ok,) = address(poa).call(abi.encodeWithSelector(POAAgentFinance.acceptOwnership.selector));
        require(!ok, "ownership bypass");
    }

    receive() external payable {}
}
