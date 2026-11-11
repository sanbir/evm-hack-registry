// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  FairSide FSDVesting — conviction NFT is released only when this claim
    equals the original vest (Code4rena, WatchPug, H-03, November 2021).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: claimVestedTokens releases fairSideConviction only when
    `amount == tokenClaim`. tokenClaim is the amount paid by this call, not
    totalClaimed. A beneficiary who already claimed part of a fully vested
    schedule receives the remaining FSD and never the NFT. A later claim
    reverts because nothing is left to pay, so the NFT stays in the contract.
    The replay block timestamp is already past the vest end. No warp.
    Vulnerable line preserved verbatim below (@> VULN). */

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }
}

interface IFSDVesting {
    function claimVestedTokens() external;
}

contract Conviction {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    function escrow(address to) external returns (uint256 tokenId) {
        require(ownerOf[1] == address(0), "Conviction: exists");
        tokenId = 1;
        ownerOf[tokenId] = to;
        balanceOf[to] += 1;
    }

    function existingOrMint(address to) external returns (uint256 tokenId) {
        tokenId = 1;
        if (ownerOf[tokenId] == address(0)) {
            ownerOf[tokenId] = to;
            balanceOf[to] += 1;
        }
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Conviction: not owner");
        require(msg.sender == from, "Conviction: not approved");
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
        ownerOf[tokenId] = to;
    }
}

contract MockFSD {
    using SafeMath for uint256;

    mapping(address => uint256) public balanceOf;
    Conviction public nft;

    function setNft(Conviction c) external {
        nft = c;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] = balanceOf[to].add(amt);
    }

    function safeTransfer(address to, uint256 amt) external {
        require(balanceOf[msg.sender] >= amt, "FSD: balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] = balanceOf[to].add(amt);
    }

    function tokenizeConviction(uint256) external returns (uint256 tokenId) {
        tokenId = nft.existingOrMint(msg.sender);
    }
}

contract FSDVesting is IFSDVesting {
    using SafeMath for uint256;

    uint256 public constant AMOUNT = 1000 ether;
    uint256 public constant PRIOR = 400 ether;
    // Replay timestamp is 1. start 0 and a 1-second duration means the vest
    // has already ended in this block. The 30-month schedule is collapsed
    // onto that single block so the fully-vested branch is the one taken.
    uint256 public constant CLIFF = 0;
    uint256 public constant DURATION = 1;

    MockFSD public fsd;
    Conviction public fairSideConviction;
    address public beneficiary;
    uint256 public amount;
    uint256 public totalClaimed;
    uint256 public lastClaimAt;
    uint256 public start;

    event TokensClaimed(address indexed beneficiary, uint256 amount, uint256 timestamp);

    modifier onlyBeneficiary() {
        require(msg.sender == beneficiary, "FSDVesting::onlyBeneficiary");
        _;
    }

    constructor(MockFSD _fsd, Conviction _nft) {
        fsd = _fsd;
        fairSideConviction = _nft;
        beneficiary = msg.sender;
        amount = AMOUNT;
        totalClaimed = PRIOR;
        start = 0;
        lastClaimAt = 0;
    }

    function calculateVestingClaim() public view returns (uint256) {
        uint256 vestedAmount;
        if (block.timestamp >= start + DURATION) {
            vestedAmount = amount;
        } else if (block.timestamp < start + CLIFF) {
            vestedAmount = 0;
        } else {
            vestedAmount = (amount * 5) / 100;
            uint256 timeAfterCliff = block.timestamp - (start + CLIFF);
            uint256 span = DURATION - CLIFF;
            vestedAmount = vestedAmount + ((amount * 95) / 100) * timeAfterCliff / span;
        }
        if (vestedAmount <= totalClaimed) {
            return 0;
        }
        return vestedAmount - totalClaimed;
    }

    function claimVestedTokens() external override onlyBeneficiary {
        uint256 tokenClaim = calculateVestingClaim();
        require(
            tokenClaim > 0,
            "FSDVesting::claimVestedTokens: Zero claimable tokens"
        );

        totalClaimed = totalClaimed.add(tokenClaim);
        lastClaimAt = block.timestamp;

        fsd.safeTransfer(msg.sender, tokenClaim);

        emit TokensClaimed(msg.sender, tokenClaim, block.timestamp);

        // @> VULN: amount is the original vest, tokenClaim is only this claim, so a prior claim never releases the NFT
        if (amount == tokenClaim) {
            uint256 tokenId = fsd.tokenizeConviction(0);
            fairSideConviction.transferFrom(address(this), msg.sender, tokenId);
        }
    }
}

contract FSDVestingFixed is IFSDVesting {
    using SafeMath for uint256;

    uint256 public constant AMOUNT = 1000 ether;
    uint256 public constant PRIOR = 400 ether;
    uint256 public constant CLIFF = 0;
    uint256 public constant DURATION = 1;

    MockFSD public fsd;
    Conviction public fairSideConviction;
    address public beneficiary;
    uint256 public amount;
    uint256 public totalClaimed;
    uint256 public lastClaimAt;
    uint256 public start;

    modifier onlyBeneficiary() {
        require(msg.sender == beneficiary, "FSDVesting::onlyBeneficiary");
        _;
    }

    constructor(MockFSD _fsd, Conviction _nft) {
        fsd = _fsd;
        fairSideConviction = _nft;
        beneficiary = msg.sender;
        amount = AMOUNT;
        totalClaimed = PRIOR;
        start = 0;
        lastClaimAt = 0;
    }

    function calculateVestingClaim() public view returns (uint256) {
        uint256 vestedAmount;
        if (block.timestamp >= start + DURATION) {
            vestedAmount = amount;
        } else if (block.timestamp < start + CLIFF) {
            vestedAmount = 0;
        } else {
            vestedAmount = (amount * 5) / 100;
            uint256 timeAfterCliff = block.timestamp - (start + CLIFF);
            uint256 span = DURATION - CLIFF;
            vestedAmount = vestedAmount + ((amount * 95) / 100) * timeAfterCliff / span;
        }
        if (vestedAmount <= totalClaimed) {
            return 0;
        }
        return vestedAmount - totalClaimed;
    }

    function claimVestedTokens() external override onlyBeneficiary {
        uint256 tokenClaim = calculateVestingClaim();
        require(tokenClaim > 0, "FSDVesting::claimVestedTokens: Zero claimable tokens");

        totalClaimed = totalClaimed.add(tokenClaim);
        lastClaimAt = block.timestamp;

        fsd.safeTransfer(msg.sender, tokenClaim);

        // FIX: compare against totalClaimed, which includes this claim
        if (amount == totalClaimed) {
            uint256 tokenId = fsd.tokenizeConviction(0);
            fairSideConviction.transferFrom(address(this), msg.sender, tokenId);
        }
    }
}

contract Exploit {
    MockFSD public fsd;
    Conviction public nft;
    FSDVesting public vesting;
    bool public laterClaimReverted;

    constructor() {
        fsd = new MockFSD();
        nft = new Conviction();
        fsd.setNft(nft);
        vesting = new FSDVesting(fsd, nft);
        fsd.mint(address(vesting), 600 ether);
        fsd.mint(address(this), 400 ether);
    }

    function run() external {
        uint256 id = nft.escrow(address(vesting));
        require(id == 1, "nft id");

        uint256 claimable = vesting.calculateVestingClaim();
        require(claimable == 600 ether, "not the fully vested remainder");

        vesting.claimVestedTokens();

        (bool ok, bytes memory err) = address(vesting).call(
            abi.encodeWithSelector(vesting.claimVestedTokens.selector)
        );
        require(!ok && err.length > 0, "follow-up claim did not revert");
        laterClaimReverted = true;

        require(nft.ownerOf(1) == address(vesting), "nft left the contract");
        require(nft.balanceOf(address(vesting)) == 1, "nft not stuck");
        require(nft.balanceOf(address(this)) == 0, "beneficiary received the nft");
        require(fsd.balanceOf(address(this)) == 1000 ether, "fsd short");
        require(vesting.totalClaimed() == 1000 ether, "not fully claimed");
    }
}
