pragma solidity >=0.7.0 <0.9.0;

// We're using a patched version of openzeppelin's `Ownable` contract based on solidity 0.7.0 but
// updated in our fork with a >=0.7.0 <0.9.0 pragma statement allowing it to be used in this repo
// for both solidity versions
import {Ownable} from "balancer-lbp-patch/v2-solidity-utils/contracts/openzeppelin/Ownable.sol";

contract BazaarManager is Ownable {
    address public feeCollector;

    // Default Swap Fee Percentages
    uint256 private constant MAX_FEE_PERCENTAGE = 1e18 / 2; // 50%

    uint256 public defaultSwapFeePercentage = 1e18 / 100; // 1%
    uint256 public defaultExitQuoteFeePercentage = 2e18 / 100; // 2%

    // Quote Tokens
    mapping(address => bool) public quoteTokens;

    // Events
    event QuoteTokenChange(address token, bool enabled);

    constructor(address _admin, address _feeCollector) Ownable() {
        feeCollector = _feeCollector;

        if (_admin != msg.sender) {
            transferOwnership(_admin);
        }
    }

    /**
     * Fees *
     */
    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "fee collector cannot be zero address");
        feeCollector = _feeCollector;
    }

    function setDefaultFeePercentages(uint256 swapPercentage, uint256 exitQuotePercentage) external onlyOwner {
        require(
            swapPercentage <= MAX_FEE_PERCENTAGE && exitQuotePercentage <= MAX_FEE_PERCENTAGE, "Invalid Fee Percentage"
        );

        defaultSwapFeePercentage = swapPercentage;
        defaultExitQuoteFeePercentage = exitQuotePercentage;
    }

    function defaultFeePercentages() external view returns (uint256, uint256) {
        return (defaultSwapFeePercentage, defaultExitQuoteFeePercentage);
    }

    /**
     * Quote Tokens *
     */
    function setQuoteToken(address token, bool enabled) external onlyOwner {
        quoteTokens[token] = enabled;
        emit QuoteTokenChange(token, enabled);
    }

    function isQuoteToken(address token) external view returns (bool) {
        return quoteTokens[token];
    }
}
