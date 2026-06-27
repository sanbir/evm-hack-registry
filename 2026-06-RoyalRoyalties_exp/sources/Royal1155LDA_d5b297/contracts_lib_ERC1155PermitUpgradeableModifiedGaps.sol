//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ECDSAUpgradeable } from "../dependencies/openzeppelin/v4_7_0/ECDSAUpgradeable.sol";
import { EIP712UpgradeableGapless } from "../dependencies/openzeppelin/v4_7_0/draft-EIP712UpgradeableGapless.sol";
import { ERC1155UpgradeableGapless } from "../dependencies/openzeppelin/v4_7_0/ERC1155UpgradeableGapless.sol";

import { IERC1155PermitUpgradeable } from "./interfaces/IERC1155PermitUpgradeable.sol";
import { __Gap17 } from "./Gaps.sol";

/**
 * @title ERC1155PermitUpgradeableModifiedGaps
 * @author Royal
 *
 * @notice ERC-1155 token with owner-level approvals via EIP-712 signatures.
 *
 * Compare with:
 *   https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.7.3/contracts/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol
 *   https://github.com/dievardump/erc721-with-permits/blob/de820e0185b3ae0d53c4cb840e1af4169159352f/contracts/ERC721WithPermit.sol
 */
abstract contract ERC1155PermitUpgradeableModifiedGaps is
    ERC1155UpgradeableGapless,
    __Gap17,
    EIP712UpgradeableGapless,
    IERC1155PermitUpgradeable
{
    // IMPORTANT:
    //   Specific to Royal LDA live contract upgrade:
    //   This contract together with the base contracts have to take up exactly 50 storage slots.
    //
    // Base contracts:
    //   [ 3 slots] ERC1155UpgradeableGapless
    //   [17 slots] __Gap17
    //   [ 2 slots] EIP712UpgradeableGapless
    uint256[8] private __gap;
    mapping(address => uint256) private _nonces;
    uint256[19] private __gap2;

    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 nonce,uint256 deadline)"
    );

    function __ERC1155Permit_init(
        string memory name,
        string memory version,
        string memory uri_
    )
        internal
        onlyInitializing
    {
        __EIP712_init_unchained(name, version);
        __ERC1155_init_unchained(uri_);
    }

    function __ERC1155Permit_init_unchained()
        internal
        onlyInitializing
    {}

    /**
     * @notice Callable by anyone to approve `spender` for all tokens using a permit signature.
     *
     * @param  owner      The address on whose behalf the spender may transfer any tokens.
     * @param  spender    Address of the spender.
     * @param  deadline   Deadline for the signature to be valid, in unix seconds.
     * @param  v          Signature component v.
     * @param  r          Signature component r.
     * @param  s          Signature component s.
     */
    function permit(
        address owner,
        address spender,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        public
        virtual
        override
    {
        require(
            block.timestamp <= deadline,
            "ERC1155Permit: expired deadline"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                owner,
                spender,
                _nonces[owner]++,
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSAUpgradeable.recover(digest, v, r, s);

        require(
            signer == owner,
            "ERC1155Permit: invalid signature"
        );

        _setApprovalForAll(owner, spender, true);
    }

    /**
     * @notice Cancel permits for a given nonce by incrementing the nonce.
     *
     * @param  owner  The owner to increment the nonce for.
     * @param  nonce  The nonce to be canceled.
     */
    function cancelNonce(
        address owner,
        uint256 nonce
    )
        external
    {
        require(
            _msgSender() == owner,
            "Sender is not the owner"
        );
        require(
            _nonces[owner]++ == nonce,
            "Nonce to cancel is not current"
        );
    }

    function nonces(
        address owner
    )
        external
        view
        returns (uint256)
    {
        return _nonces[owner];
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR()
        external
        view
        returns (bytes32)
    {
        return _domainSeparatorV4();
    }
}
