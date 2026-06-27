// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.21;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

import "./OwnableMaster.sol";

error AlreadyReserved();

contract PositionNFTs is ERC721Enumerable, OwnableMaster {

    string public baseURI;
    string public baseExtension = ".json";

    uint256 public totalReserved;
    mapping(address => uint256) public reserved;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _initBaseURI
    )
        ERC721(
            _name,
            _symbol
        )
        OwnableMaster(
            msg.sender
        )
    {
        baseURI = _initBaseURI;
    }

    function reservePosition()
        external
        returns (uint256)
    {
        return _reservePositionForUser(
            msg.sender
        );
    }

    function reservePositionForUser(
        address _user
    )
        external
        returns (uint256)
    {
        return _reservePositionForUser(
            _user
        );
    }

    function _reservePositionForUser(
        address _user
    )
        internal
        returns (uint256)
    {
        if (reserved[_user] > 0) {
            revert AlreadyReserved();
        }

        uint256 reservedId = getNextExpectedId();
        reserved[_user] = reservedId;

        totalReserved =
        totalReserved + 1;

        return reservedId;
    }

    function getNextExpectedId()
        public
        view
        returns (uint256)
    {
        return totalReserved + totalSupply();
    }

    /**
     * @dev Mints NFT for sender, without it
     * user can not use WiseLending protocol
     */
    function mintPosition()
        external
    {
        _mintPositionForUser(
            msg.sender
        );
    }

    /**
     * @dev See {IERC721-getApproved}.
     */
    function getApprovedSoft(
        uint256 tokenId
    )
        external
        view
        returns (address)
    {
        if (_exists(tokenId) == false) {
            return ZERO_ADDRESS;
        }

        return getApproved(
            tokenId
        );
    }

    /**
     * @dev Mints NFT for _user, without it
     * user can not use WiseLending protocol
     */
    function mintPositionForUser(
        address _user
    )
        external
        returns (uint256)
    {
        return _mintPositionForUser(
            _user
        );
    }

    function _mintPositionForUser(
        address _user
    )
        internal
        returns (uint256)
    {
        uint256 nftId = reserved[
            _user
        ];

        if (nftId > 0) {
            delete reserved[
                _user
            ];

            totalReserved--;

        } else {
            nftId = getNextExpectedId();
        }

        _safeMint(
            _user,
            nftId
        );

        return nftId;
    }

    function approve(
        address _spender,
        uint256 _nftId
    )
        public
        override(
            ERC721,
            IERC721
        )
    {
        if (_nftId == 0) {
            return;
        }

        if (reserved[msg.sender] == _nftId) {
            approveNative(
                _spender,
                _mintPositionForUser(
                    msg.sender
                )
            );

            return;
        }

        approveNative(
            _spender,
            _nftId
        );
    }

    function approveNative(
        address to,
        uint256 tokenId
    )
        public
    {
        address owner = ERC721.ownerOf(
            tokenId
        );

        require(
            _msgSender() == owner ||
            isApprovedForAll(owner, _msgSender()),
            "ERC721: INVALID_APPROVE"
        );

        _approve(
            to,
            tokenId
        );
    }

    /**
     * @dev Returns positions of owner
     */
    function walletOfOwner(
        address _owner
    )
        external
        view
        returns (uint256[] memory)
    {
        uint256 reservedId = reserved[
            _owner
        ];

        uint256 ownerTokenCount = balanceOf(
            _owner
        );

        uint256 reservedCount;

        if (reservedId > 0) {
            reservedCount = 1;
        }

        uint256[] memory tokenIds = new uint256[](
            ownerTokenCount + reservedCount
        );

        uint256 i;

        for (i; i < ownerTokenCount; ++i) {
            tokenIds[i] = tokenOfOwnerByIndex(
                _owner,
                i
            );
        }

        if (reservedId > 0) {
            tokenIds[i] = reservedId;
        }

        return tokenIds;
    }

    /**
     * @dev Allows to update base target for MetaData.
     */
    function setBaseURI(
        string memory _newBaseURI
    )
        external
        onlyMaster
    {
        baseURI = _newBaseURI;
    }

    function setBaseExtension(
        string memory _newBaseExtension
    )
        external
        onlyMaster
    {
        baseExtension = _newBaseExtension;
    }

    /**
     * @dev Returns path to MetaData URI
     */
    function tokenURI(
        uint256 _tokenId
    )
        public
        view
        override
        returns (string memory)
    {
        require(
            _exists(_tokenId) == true,
            "PositionNFTs: WRONG_TOKEN"
        );

        string memory currentBaseURI = _baseURI();

        if (bytes(currentBaseURI).length == 0) {
            return "";
        }

        return string(
            abi.encodePacked(
                currentBaseURI,
                _toString(_tokenId),
                baseExtension
            )
        );
    }

    /**
     * @dev Converts tokenId uint to string.
     */
    function _toString(
        uint256 _tokenId
    )
        internal
        pure
        returns (string memory str)
    {
        if (_tokenId == 0) {
            return "0";
        }

        uint256 j = _tokenId;
        uint256 length;

        while (j != 0) {
            length++;
            j /= 10;
        }

        bytes memory bstr = new bytes(
            length
        );

        uint256 k = length;
        j = _tokenId;

        while (j != 0) {
            bstr[--k] = bytes1(
                uint8(
                    48 + j % 10
                )
            );
            j /= 10;
        }

        str = string(
            bstr
        );
    }
}
