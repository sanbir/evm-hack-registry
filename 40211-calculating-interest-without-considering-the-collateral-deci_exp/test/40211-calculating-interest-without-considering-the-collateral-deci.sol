// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cryptex Vault.outstandingInterestOf — Cantina, September 2024.
    Interest stored in 18-decimal TCAP units is converted with price/price and
    never scaled to 6-decimal collateral. 0.1 TCAP becomes 0.1e18 instead of
    0.1e6. collateralOf underflows, so the 100e6 USDC deposit cannot be withdrawn.
    The fix multiplies by 10**assetDecimals and divides by 1e18.
*/

contract Collateral {
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Vault {
    uint256 public constant TCAP_PRICE = 1e18;
    uint256 public constant COLLATERAL_PRICE = 1e18;
    uint8 public constant assetDecimals = 6;

    Collateral public collateral;
    mapping(bytes32 => uint256) public interestOf;
    mapping(bytes32 => uint256) public deposits;

    constructor(Collateral c) {
        collateral = c;
    }

    function _toMintId(address user, uint96 pocketId) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, pocketId));
    }

    function tcapLatestPrice() public pure returns (uint256) {
        return TCAP_PRICE;
    }

    function latestPrice() public pure returns (uint256) {
        return COLLATERAL_PRICE;
    }

    function fundPocket(address user, uint96 pocketId, uint256 amount, uint256 interest) external {
        deposits[_toMintId(user, pocketId)] = amount;
        interestOf[_toMintId(user, pocketId)] = interest;
    }

    function outstandingInterestOf(address user, uint96 pocketId) public view returns (uint256) {
        uint256 interestAmount = interestOf[_toMintId(user, pocketId)];
        uint256 quoted = interestAmount * tcapLatestPrice() / latestPrice();
        return quoted;
    }

    function collateralOf(address user, uint96 pocketId) public view returns (uint256) {
        // @> VULN: TCAP interest is converted without collateral decimals, so 0.1e18 is charged instead of 0.1e6
        return deposits[_toMintId(user, pocketId)] - outstandingInterestOf(user, pocketId);
    }

    function withdraw(address user, uint96 pocketId) external returns (uint256 amount) {
        amount = collateralOf(user, pocketId);
        deposits[_toMintId(user, pocketId)] = 0;
        require(collateral.transfer(user, amount), "pay");
    }
}

contract VaultFixed {
    uint256 public constant TCAP_PRICE = 1e18;
    uint256 public constant COLLATERAL_PRICE = 1e18;
    uint8 public constant assetDecimals = 6;

    Collateral public collateral;
    mapping(bytes32 => uint256) public interestOf;
    mapping(bytes32 => uint256) public deposits;

    constructor(Collateral c) {
        collateral = c;
    }

    function _toMintId(address user, uint96 pocketId) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, pocketId));
    }

    function fundPocket(address user, uint96 pocketId, uint256 amount, uint256 interest) external {
        deposits[_toMintId(user, pocketId)] = amount;
        interestOf[_toMintId(user, pocketId)] = interest;
    }

    function outstandingInterestOf(address user, uint96 pocketId) public view returns (uint256) {
        uint256 interestAmount = interestOf[_toMintId(user, pocketId)];
        return interestAmount * TCAP_PRICE * 10 ** uint256(assetDecimals) / COLLATERAL_PRICE / 10 ** 18;
    }

    function withdraw(address user, uint96 pocketId) external returns (uint256 amount) {
        amount = deposits[_toMintId(user, pocketId)] - outstandingInterestOf(user, pocketId);
        deposits[_toMintId(user, pocketId)] = 0;
        require(collateral.transfer(user, amount), "pay");
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 100e6;
    uint256 public constant INTEREST = 0.1 ether;
    uint96 public constant POCKET = 1;

    Collateral public collateral;
    Vault public vault;
    uint256 public quotedInterest;
    bool public withdrawReverted;
    uint256 public stillLocked;

    constructor() {
        collateral = new Collateral();
        vault = new Vault(collateral);
        collateral.mint(address(vault), DEPOSIT);
        vault.fundPocket(address(this), POCKET, DEPOSIT, INTEREST);
    }

    function run() external {
        quotedInterest = vault.outstandingInterestOf(address(this), POCKET);
        require(quotedInterest == INTEREST, "quotes 0.1e18");
        require(quotedInterest > DEPOSIT, "quote exceeds 100 USDC");
        try vault.withdraw(address(this), POCKET) returns (uint256) {
            withdrawReverted = false;
        } catch {
            withdrawReverted = true;
        }
        stillLocked = collateral.balanceOf(address(vault));
        require(withdrawReverted, "withdraw underflows");
        require(stillLocked == DEPOSIT, "100 USDC stays locked");
        require(collateral.balanceOf(address(this)) == 0, "user received nothing");
    }
}
