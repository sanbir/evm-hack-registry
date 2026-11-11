// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bando — service fees locked in BandoRouterV1
    (Zokyo, finding #45849, report 2024-11-25)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: requestService requires msg.value == weiAmount + feeAmount,
    then deposits only weiAmount into the escrow. feeAmount stays in the
    router, and the audited router has no function that withdraws it.

    The check and the deposit below are the lines the report quotes.
    Source: bandohq/evm-fulfillment-protocol@a1e3aa2abb472d618bf479a76acf9855f760b145
    contracts/libraries/FulfillmentRequestLib.sol validateRequest
    contracts/BandoRouterV1.sol requestService
*/

library Math {
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }
}

struct FulFillmentRequest {
    address payable payer;
    uint256 weiAmount;
    uint256 fiatAmount;
    string serviceRef;
}

struct Service {
    uint256 feeAmount;
    address payable beneficiary;
}

contract BandoFulfillableV1 {
    uint256 public received;

    function deposit(uint256 serviceID, FulFillmentRequest calldata request) external payable {
        require(serviceID != 0, "Service ID is invalid");
        require(msg.value == request.weiAmount, "escrow funded with weiAmount");
        received += msg.value;
    }
}

/// @title BandoRouterV1 (reduced) — fee is taken, never withdrawn.
contract BandoRouterV1 {
    using Math for uint256;

    error OverflowError();
    error AmountMismatch();

    address payable public _escrow;
    address public owner;
    mapping(uint256 => Service) internal _services;

    constructor(address payable escrow_) {
        _escrow = escrow_;
        owner = msg.sender;
    }

    function setService(uint256 serviceID, uint256 feeAmount, address payable beneficiary) external {
        require(msg.sender == owner, "only owner");
        _services[serviceID] = Service({feeAmount: feeAmount, beneficiary: beneficiary});
    }

    function requestService(uint256 serviceID, FulFillmentRequest memory request) public payable returns (bool) {
        Service memory service = _services[serviceID];
        (bool success, uint256 total_amount) = request.weiAmount.tryAdd(service.feeAmount);
        if (!success) {
            revert OverflowError();
        }
        if (msg.value != total_amount) {
            revert AmountMismatch();
        }
        // @> VULN: only weiAmount is forwarded, so service.feeAmount is locked here with no withdraw
        BandoFulfillableV1(_escrow).deposit{value: request.weiAmount}(serviceID, request);
        // FIX: add withdrawServiceFees() that pays address(this).balance to the owner
        return true;
    }
}

/// @title Control: same requestService, plus the missing fee withdraw. Pays the owner N.
contract BandoRouterFixed {
    using Math for uint256;

    error OverflowError();
    error AmountMismatch();

    address payable public _escrow;
    address public owner;
    mapping(uint256 => Service) internal _services;

    constructor(address payable escrow_, address owner_) {
        _escrow = escrow_;
        owner = owner_;
    }

    function setService(uint256 serviceID, uint256 feeAmount, address payable beneficiary) external {
        require(msg.sender == owner, "only owner");
        _services[serviceID] = Service({feeAmount: feeAmount, beneficiary: beneficiary});
    }

    function requestService(uint256 serviceID, FulFillmentRequest memory request) public payable returns (bool) {
        Service memory service = _services[serviceID];
        (bool success, uint256 total_amount) = request.weiAmount.tryAdd(service.feeAmount);
        if (!success) {
            revert OverflowError();
        }
        if (msg.value != total_amount) {
            revert AmountMismatch();
        }
        BandoFulfillableV1(_escrow).deposit{value: request.weiAmount}(serviceID, request);
        return true;
    }

    function withdrawServiceFees() external {
        require(msg.sender == owner, "only owner");
        uint256 amount = address(this).balance;
        (bool ok,) = owner.call{value: amount}("");
        require(ok, "fee transfer failed");
    }
}

contract Exploit {
    uint256 public constant FEE = 1 ether;
    uint256 public constant WEI_AMOUNT = 2 ether;
    uint256 public constant SERVICE_ID = 1;
    address public constant BENEFICIARY = 0x2222222222222222222222222222222222222222;

    BandoFulfillableV1 public escrow;
    BandoRouterV1 public router;
    uint256 public stuckFees;
    bool public withdrawExisted;

    function run() external payable {
        escrow = new BandoFulfillableV1();
        router = new BandoRouterV1(payable(address(escrow)));
        router.setService(SERVICE_ID, FEE, payable(BENEFICIARY));

        FulFillmentRequest memory request = FulFillmentRequest({
            payer: payable(msg.sender),
            weiAmount: WEI_AMOUNT,
            fiatAmount: 100,
            serviceRef: "gift"
        });
        require(msg.value == WEI_AMOUNT + FEE, "payer sent wei plus fee");
        router.requestService{value: msg.value}(SERVICE_ID, request);

        uint256 escrowGot = address(escrow).balance;
        require(escrowGot == WEI_AMOUNT, "escrow should hold only the principal");

        (bool withdrew,) = address(router).call(abi.encodeWithSignature("withdrawServiceFees()"));
        withdrawExisted = withdrew;
        require(!withdrew, "fee withdraw should not exist");

        stuckFees = address(router).balance;
        require(stuckFees == FEE, "service fee not stuck");
    }
}
