// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Pawn {
    struct Position {
        uint256 offer;
        uint256 collateralValue;
        uint256 deadline;
        bool active;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextId;

    function pawn(uint256 collateralValue, uint256 offerAmount, uint256 deadline) external returns (uint256 id) {
        // @> VULN: backend-signed offerAmount is accepted without on-chain LTV/oracle validation.
        id = nextId++;
        positions[id] = Position(offerAmount, collateralValue, deadline, true);
    }

    function updateCollateralValue(uint256 id, uint256 value) external {
        positions[id].collateralValue = value;
    }

    function liquidate(uint256 id, uint256 nowTs) external {
        Position storage p = positions[id];
        require(p.active, "inactive");
        // @> VULN: liquidation is time-only; no unhealthy-position path exists.
        require(nowTs >= p.deadline, "deadline");
        p.active = false;
    }

    function badDebt(uint256 id) external view returns (uint256) {
        Position memory p = positions[id];
        return p.offer > p.collateralValue ? p.offer - p.collateralValue : 0;
    }
}

contract Exploit {
    Pawn public pawnContract;
    uint256 public positionId;
    uint256 public badDebt;
    bool public earlyLiquidationBlocked;

    constructor() {
        pawnContract = new Pawn();
    }

    function run() external {
        // Backend signs 1,800 against a 2,000 appraisal (no on-chain check).
        positionId = pawnContract.pawn(2_000, 1_800, 1_000);
        // Market value falls to 1,600 while the loan is still within its term.
        pawnContract.updateCollateralValue(positionId, 1_600);
        (bool ok,) = address(pawnContract).call(
            abi.encodeWithSelector(Pawn.liquidate.selector, positionId, 500)
        );
        earlyLiquidationBlocked = !ok;
        badDebt = pawnContract.badDebt(positionId);
        require(earlyLiquidationBlocked && badDebt == 200, "insolvency path absent");
    }
}
