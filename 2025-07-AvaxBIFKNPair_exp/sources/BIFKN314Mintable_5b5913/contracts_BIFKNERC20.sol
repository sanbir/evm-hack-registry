// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./ERC20.sol";

/**
 * @title BIFKNERC20
 * @dev This contract represents the BIFKNERC20 token.
 */
contract BIFKNERC20 is ERC20 {
    /**
     * @dev The `DOMAIN_SEPARATOR` is a unique identifier for the contract domain.
     * It is used to prevent replay attacks and to ensure that the contract is interacting with the correct domain.
     */
    bytes32 public DOMAIN_SEPARATOR;

    /**
     * @dev The hash of the permit type used in the EIP-2612 permit function.
     */
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    /**
     * @dev A mapping that stores the nonces for each address.
     * Nonces are used to prevent replay attacks in certain operations.
     * The key of the mapping is the address and the value is the nonce.
     */
    mapping(address => uint256) public nonces;

    /**
     * @dev Error indicating that the name and symbol must not be empty.
     */
    error NameAndSymbolMustNotBeEmpty();

    /**
     * @dev Error indicating that the name and symbol of the ERC20 token have already been set.
     */
    error NameAndSymbolAlreadySet();

    /**
     * @dev Error indicating that the signature has expired for ERC2612.
     * @param deadline The timestamp representing the expiration deadline.
     */
    error ERC2612ExpiredSignature(uint256 deadline);
    /**
     * @dev Error indicating that the signer is invalid.
     * @param signer The address of the invalid signer.
     * @param owner The address of the token owner.
     */
    error ERC2612InvalidSigner(address signer, address owner);

    /**
     * @dev Constructor function for the BIFKNERC20 contract.
     * It initializes the ERC20 contract and the EIP712 contract.
     * It also sets the DOMAIN_SEPARATOR variable using the _domainSeparatorV4 function.
     */
    constructor() ERC20() {}

    /**
     * @dev Initializes the ERC20 token with the given name and symbol.
     * @param tokenName The name of the token.
     * @param tokenSymbol The symbol of the token.
     */
    function initialize(
        string memory tokenName,
        string memory tokenSymbol
    ) public virtual {
        if (bytes(tokenName).length == 0 || bytes(tokenSymbol).length == 0) {
            revert NameAndSymbolMustNotBeEmpty();
        }
        if (bytes(_name).length != 0 || bytes(_symbol).length != 0) {
            revert NameAndSymbolAlreadySet();
        }
        _name = tokenName;
        _symbol = tokenSymbol;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(_name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @dev Allows `owner` to approve `spender` to spend `value` tokens on their behalf using a signed permit.
     * @param owner The address of the token owner.
     * @param spender The address of the spender.
     * @param value The amount of tokens to be approved.
     * @param deadline The deadline timestamp for the permit.
     * @param v The recovery id of the permit signature.
     * @param r The r value of the permit signature.
     * @param s The s value of the permit signature.
     * Requirements:
     * - The permit must not be expired (deadline not reached).
     * - The permit signature must be valid.
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (deadline < block.timestamp) {
            revert ERC2612ExpiredSignature(deadline);
        }
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        owner,
                        spender,
                        value,
                        nonces[owner]++,
                        deadline
                    )
                )
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        if (recoveredAddress == address(0) || recoveredAddress != owner) {
            revert ERC2612InvalidSigner(recoveredAddress, owner);
        }

        _approve(owner, spender, value);
    }

    /**
     * @dev Burns a specific amount of tokens from the caller's balance.
     * @param value The amount of tokens to be burned.
     */
    function burn(uint256 value) public virtual {
        _burn(_msgSender(), value);
    }

    /**
     * @dev Burns a specific amount of tokens from the specified account.
     *
     * Requirements:
     * - The caller must have an allowance for `account`'s tokens of at least `value`.
     *
     * Emits a {Transfer} event with `from` set to `account`.
     */
    function burnFrom(address account, uint256 value) public virtual {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }
}
