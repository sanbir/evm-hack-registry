// SPDX-License-Identifier: MIT
// Fork from OpenZeppelin Contracts (v4.3.2) (token/ERC20/extensions/ERC20FlashMint.sol)

pragma solidity ^0.8.0;

import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/interfaces/IERC3156Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

/**
 * @dev Implementation of the ERC3156 Flash loans extension, as defined in
 * https://eips.ethereum.org/EIPS/eip-3156[ERC-3156].
 *
 * Adds the {flashLoan} method, which provides flash loan support at the token
 * level. By default there is no fee, but this can be changed by overriding {flashFee}.
 *
 * _Available since v4.1._
 */
abstract contract ERC20FlashMintUpgradeable is
    Initializable,
    OwnableUpgradeable,
    ERC20Upgradeable,
    IERC3156FlashLenderUpgradeable
{
    uint256 public maxFlashLoanAmount;
    uint256 public flashLoanFee; // unit: base 10000
    address public flashLoanFeeTo;

    function __ERC20FlashMint_init(
        uint256 _maxFlashLoanAmount,
        uint256 _flashLoanFee,
        address _flashLoanFeeTo
    ) internal initializer {
        __Context_init_unchained();
        __ERC20FlashMint_init_unchained(_maxFlashLoanAmount, _flashLoanFee, _flashLoanFeeTo);
    }

    function __ERC20FlashMint_init_unchained(
        uint256 _maxFlashLoanAmount,
        uint256 _flashLoanFee,
        address _flashLoanFeeTo
    ) internal initializer {
        require(_flashLoanFeeTo != address(0), 'zero address X');
        require(_flashLoanFee < 10000, 'invalid flash loan fee');

        maxFlashLoanAmount = _maxFlashLoanAmount;
        flashLoanFee = _flashLoanFee;
        flashLoanFeeTo = _flashLoanFeeTo;
    }

    bytes32 private constant _RETURN_VALUE = keccak256('ERC3156FlashBorrower.onFlashLoan');

    /**
     * @notice Change the max flash loan
     */
    function setMaxFlashLoanAmount(uint256 _maxFlashLoanAmount) external onlyOwner {
        maxFlashLoanAmount = _maxFlashLoanAmount;
    }

    /**
     * @notice Change the flash loan fee
     */
    function setFlashLoanFee(uint256 _flashLoanFee) external onlyOwner {
        require(_flashLoanFee < 10000, 'invalid flash loan fee');
        flashLoanFee = _flashLoanFee;
    }

    /**
     * @notice Change the flash loan fee to
     */
    function setFlashLoanFeeTo(address _flashLoanFeeTo) external onlyOwner {
        require(flashLoanFeeTo != address(0), 'zero address');
        flashLoanFeeTo = _flashLoanFeeTo;
    }

    /**
     * @dev Returns the maximum amount of tokens available for loan.
     * @param token The address of the token that is requested.
     * @return The amont of token that can be loaned.
     */
    function maxFlashLoan(address token) public view override returns (uint256) {
        return token == address(this) ? maxFlashLoanAmount : 0;
    }

    /**
     * @dev Returns the fee applied when doing flash loans. By default this
     * implementation has 0 fees. This function can be overloaded to make
     * the flash loan mechanism deflationary.
     * @param token The token to be flash loaned.
     * @param amount The amount of tokens to be loaned.
     * @return The fees applied to the corresponding flash loan.
     */
    function flashFee(address token, uint256 amount) public view virtual override returns (uint256) {
        require(token == address(this), 'ERC20FlashMint: wrong token');
        return (amount * flashLoanFee) / 10000;
    }

    /**
     * @dev Performs a flash loan. New tokens are minted and sent to the
     * `receiver`, who is required to implement the {IERC3156FlashBorrower}
     * interface. By the end of the flash loan, the receiver is expected to own
     * amount + fee tokens and have them approved back to the token contract itself so
     * they can be burned.
     * @param receiver The receiver of the flash loan. Should implement the
     * {IERC3156FlashBorrower.onFlashLoan} interface.
     * @param token The token to be flash loaned. Only `address(this)` is
     * supported.
     * @param amount The amount of tokens to be loaned.
     * @param data An arbitrary datafield that is passed to the receiver.
     * @return `true` if the flash loan was successful.
     */
    // This function can reenter, but it doesn't pose a risk because it always preserves the property that the amount
    // minted at the beginning is always recovered and burned at the end, or else the entire function will revert.
    // slither-disable-next-line reentrancy-no-eth
    function flashLoan(
        IERC3156FlashBorrowerUpgradeable receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) public virtual override returns (bool) {
        require(amount <= maxFlashLoan(token), 'ERC20FlashMint: amount exceeds maxFlashLoan');
        uint256 fee = flashFee(token, amount);
        _mint(address(receiver), amount);
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) == _RETURN_VALUE,
            'ERC20FlashMint: invalid return value'
        );
        uint256 currentAllowance = allowance(address(receiver), address(this));
        require(currentAllowance >= amount + fee, 'ERC20FlashMint: allowance does not allow refund');
        // spend allowance
        _approve(address(receiver), address(this), currentAllowance - amount - fee);
        _burn(address(receiver), amount + fee);

        // mint fee
        if (fee > 0) {
            // flashLoanFeeTo is a non-zero address
            _mint(flashLoanFeeTo, fee);
        }
        return true;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[47] private __gap;
}
