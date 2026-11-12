// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Roots — claimCollateral pulls from the TroveManager, but the collateral
    sits in the Staker (Pashov, February 2025, H-04). SYNTHETIC, cheatcode-free.
    The blamed transfer is verbatim (@> VULN).

    After a partial liquidation the borrower is owed 6 collateral. claimCollateral
    transfers from the TroveManager, which holds 0, so the call reverts and the
    6 stay in the Staker. The fixed claim releases them from the Staker and the
    borrower receives 6. */

contract Collateral {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Staker {
    Collateral public token;

    constructor(Collateral _token) {
        token = _token;
    }

    function onWithdrawal(address to, uint256 amount) external {
        require(token.transfer(to, amount), "release");
    }
}

contract TroveManager {
    Collateral public collateralToken;
    Staker public staker;
    mapping(address => uint256) public surplusBalances;

    constructor(Collateral _token, Staker _staker) {
        collateralToken = _token;
        staker = _staker;
    }

    function addCollateralSurplus(address borrower, uint256 collSurplus) external {
        surplusBalances[borrower] += collSurplus;
    }

    function claimCollateral(address receiver) external {
        uint256 claimableColl = surplusBalances[msg.sender];
        require(claimableColl > 0, "No collateral available to claim");
        surplusBalances[msg.sender] = 0;
        // @> VULN: the collateral is staked, so this transfer pulls from the TroveManager and reverts.
        collateralToken.transfer(receiver, claimableColl);
    }

    function claimFixed(address receiver) external {
        uint256 claimableColl = surplusBalances[msg.sender];
        require(claimableColl > 0, "No collateral available to claim");
        surplusBalances[msg.sender] = 0;
        staker.onWithdrawal(receiver, claimableColl);
    }
}

contract Borrower {
    function claim(TroveManager tm, address receiver) external returns (bool ok) {
        try tm.claimCollateral(receiver) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function claimFixed(TroveManager tm, address receiver) external {
        tm.claimFixed(receiver);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 6 ether;

    Collateral public token; // nonce 1
    Staker public staker; // nonce 2
    TroveManager public tm; // nonce 3
    Borrower public borrower; // nonce 4
    bool public claimed;
    uint256 public stuck;
    uint256 public paid;

    constructor() {
        token = new Collateral();
        staker = new Staker(token);
        tm = new TroveManager(token, staker);
        borrower = new Borrower();
    }

    function run() external {
        token.mint(address(staker), AMOUNT);
        tm.addCollateralSurplus(address(borrower), AMOUNT);
        claimed = borrower.claim(tm, msg.sender);
        stuck = token.balanceOf(address(staker));
        paid = token.balanceOf(msg.sender);
        require(claimed == false, "claim should revert");
        require(stuck == AMOUNT, "6 did not stay in the staker");
        require(paid == 0, "borrower was paid");
        require(tm.surplusBalances(address(borrower)) == AMOUNT, "surplus was cleared");
    }
}
