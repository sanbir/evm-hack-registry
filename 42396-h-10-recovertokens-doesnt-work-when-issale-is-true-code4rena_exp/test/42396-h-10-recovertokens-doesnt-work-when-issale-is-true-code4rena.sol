// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Streaming Protocol — recoverTokens broken when isSale is true
    (Code4rena 2021-11-streaming, finding #42396, H-10, reporter harleythedog)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    In sale mode, creatorClaimSoldTokens transfers depositTokenAmount to the
    creator but does NOT update redeemedDepositTokens (or depositTokenAmount).
    Later recoverTokens computes:
        excess = balance - (depositTokenAmount - redeemedDepositTokens)
    with redeemedDepositTokens still 0, so it still thinks the full deposit
    liability is outstanding. Any truly excess deposit tokens (e.g. donations
    / leftover dust that should be recoverable) are under-accounted and either
    the call reverts on underflow or transfers less than the real excess —
    permanently locking those tokens.

    Harm: after a sale claim, 200 excess tokens that should be recoverable are
    locked (recoverTokens reverts or returns 0 while balance still holds them).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Locke — sale claim + recoverTokens deposit branch.
contract Locke {
    address public streamCreator;
    address public depositToken;
    address public rewardToken;
    bool public isSale;
    bool public claimedDepositTokens;
    uint256 public depositTokenAmount; // uint112 in real code; uint256 fine here
    uint256 public redeemedDepositTokens;
    uint256 public endDepositLock; // 0 => unlocked
    uint256 public endStream; // 0 => stream ended for claim

    bool private locked;

    modifier lock() {
        require(!locked, "LOCKED");
        locked = true;
        _;
        locked = false;
    }

    constructor(address creator_, address dep_, address rew_) {
        streamCreator = creator_;
        depositToken = dep_;
        rewardToken = rew_;
        isSale = true;
        endDepositLock = 0;
        endStream = 0;
    }

    function seedSale(uint256 depositAmt, uint256 excessDust) external {
        depositTokenAmount = depositAmt;
        redeemedDepositTokens = 0;
        // balance = deposits to be claimed by creator + recoverable excess dust
        MockERC20(depositToken).mint(address(this), depositAmt + excessDust);
    }

    /**
     *  @dev Faithful reduction of creatorClaimSoldTokens.
     *  Does NOT touch redeemedDepositTokens / depositTokenAmount.
     */
    function creatorClaimSoldTokens(address destination) public lock {
        // can only claim when its a sale
        require(isSale, "!sale");

        // only can claim once
        require(!claimedDepositTokens, "claimed");
        // creator is claiming
        require(msg.sender == streamCreator, "!creator");
        // stream ended
        require(block.timestamp >= endStream, "stream");

        uint256 amount = depositTokenAmount;
        claimedDepositTokens = true;
        // @> VULN: does not set redeemedDepositTokens = depositTokenAmount (or
        // zero depositTokenAmount). recoverTokens still subtracts the full
        // original deposit liability and under-counts recoverable excess.
        // FIX: redeemedDepositTokens = depositTokenAmount; after the transfer.

        MockERC20(depositToken).transfer(destination, amount);
    }

    /**
     *  @dev Faithful reduction of recoverTokens deposit branch.
     */
    function recoverTokens(address token, address recipient) public lock {
        require(msg.sender == streamCreator, "!creator");
        if (token == depositToken) {
            require(block.timestamp > endDepositLock, "time");
            // breaks when isSale && creatorClaimSoldTokens already ran:
            // depositTokenAmount still full, redeemedDepositTokens still 0
            uint256 excess = MockERC20(token).balanceOf(address(this)) - (depositTokenAmount - redeemedDepositTokens);
            MockERC20(token).transfer(recipient, excess);
            return;
        }
    }
}

contract Exploit {
    MockERC20 public depositTok; // CREATE nonce 1
    MockERC20 public rewardTok; // CREATE nonce 2
    Locke public stream; // CREATE nonce 3

    uint256 public constant DEPOSIT = 1000;
    uint256 public constant EXCESS = 200; // dust that should be recoverable post-sale

    constructor() {
        depositTok = new MockERC20();
        rewardTok = new MockERC20();
        stream = new Locke(address(this), address(depositTok), address(rewardTok));
        stream.seedSale(DEPOSIT, EXCESS);
    }

    function run() external {
        // Creator claims sold deposits — leaves EXCESS dust in the stream.
        stream.creatorClaimSoldTokens(address(this));
        require(depositTok.balanceOf(address(this)) == DEPOSIT, "sale claim");
        require(depositTok.balanceOf(address(stream)) == EXCESS, "excess remains");
        // Accounting still thinks full deposit liability is outstanding:
        require(stream.depositTokenAmount() == DEPOSIT, "amt unchanged");
        require(stream.redeemedDepositTokens() == 0, "redeemed still 0");

        // recoverTokens: excess_calc = 200 - (1000 - 0) → underflow revert (0.8+)
        bool recovered;
        try stream.recoverTokens(address(depositTok), address(this)) {
            recovered = true;
        } catch {
            recovered = false;
        }
        require(!recovered, "recover should fail or under-deliver");

        // HARM: excess tokens permanently locked — cannot be recovered.
        require(depositTok.balanceOf(address(stream)) == EXCESS, "excess locked in stream");
    }
}
