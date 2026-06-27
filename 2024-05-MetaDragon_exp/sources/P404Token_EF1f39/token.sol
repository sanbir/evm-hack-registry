// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.0 (token/ERC20/IERC20.sol)
pragma solidity ^0.8.19;

import "./ERC20.sol";
import "./IERC721Metadata.sol";
import "./IERC721Receiver.sol";
import "./IERC165.sol";

interface IERC721Enumerable {
    function totalSupply() external view returns (uint256);
    function tokenOfOwnerByIndex(
        address owner,
        uint256 index
    ) external view returns (uint256);
    function tokenByIndex(uint256 index) external view returns (uint256);
}

interface IERC721Burnable {
    function burn(uint256 tokenId) external;
}

interface IERC721Mintable {
    function mint(address to) external;
}

interface iERC721CheckAuth {
    function isAuthorized(
        address _owner,
        address _spender,
        uint256 _tokenId
    ) external view returns (bool);
}

interface IP404 {
    /**
        is the parameter a valid ERC721 token id or ERC20 amount
     */
    function isValidTokenId(
        uint256 _tokenOrAmount
    ) external view returns (bool);
}

contract P404Token is ERC20, IP404 {
    address public erc721;

    uint256 public constant MAX_SUPPLY = 300000000 * 10 ** 18;

    uint256 public constant MAX_ERC20_TOKENS = 300000000 * 10 ** 18;
    uint256 public constant TRANSFORM_PRICE = 10000 * 10 ** 18;
    uint256 public constant TRANSFORM_LOSE_RATE = 200; // 2%
    uint256 public constant MAX_NFT_MINT = 4000; // TOTAL
    uint256 public constant MAX_MINT_VALUE = 0.6 ether;

    // uint256 public constant MINT_PRICE = 0.2 ether;
    uint256 public constant MINT_PRICE = 0.2 ether;
    uint256 public nftMinted;

    address public feeTo;

    address public owner;

    event FromTokenToNFT(address from, uint256 amount);
    event FromNFTToToken(address from, uint256 tokenId);
    event PayToMint(address from, uint256 price, uint256 tokenId);

    mapping(address => bool) public allowlist;
    
    mapping(address => uint256) public mintedAmount;

    constructor(
        string memory _name,
        string memory _symbol,
        address _erc721,
        address _feeTo
    ) ERC20(_name, _symbol) {
        _mint(msg.sender, 260000000 * 10 ** 18);
        erc721 = _erc721;
        feeTo = _feeTo;
        owner = msg.sender;
    }

    // set white list
    function batchSetAllowlist(
        address[] calldata _addres,
        bool _allow
    ) external {
        require(owner == msg.sender, "META: no owner");
        for (uint256 i = 0; i < _addres.length; i++) {
            allowlist[_addres[i]] = _allow;
        }
    }

    function isValidTokenId(uint256 tokenId) public pure returns (bool) {
        // return tokenId > 200000000 * 10 ** 18;
        return tokenId < 30001;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        if (isValidTokenId(value)) {
            require(
                iERC721CheckAuth(erc721).isAuthorized(from, msg.sender, value),
                "P404: not authorized"
            );
            IERC721(erc721).safeTransferFrom(from, to, value);
            if (to == address(this)) {
                transform(value);
            }
        } else {
            super.transferFrom(from, to, value);
        }
        return true;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        // if to is this contract, transform
        if (!isValidTokenId(value)) {
            super._update(from, to, value);
        }

        if (to == address(this) || to == erc721) {
            transform(value);
        } else {
            if (isValidTokenId(value)) {
                // erc721 transfer
                // check auth
                if (from != address(0)) {
                    require(
                        iERC721CheckAuth(erc721).isAuthorized(
                            from,
                            msg.sender,
                            value
                        ),
                        "P404: not authorized"
                    );
                }
                IERC721(erc721).safeTransferFrom(from, to, value);
            }
        }
    }

    // transform
    function transform(uint256 tokenIdOrValue) internal {
        if (isValidTokenId(tokenIdOrValue)) {
            _erc721ToErc20(tokenIdOrValue);
        } else {
            _erc20ToErc721(tokenIdOrValue);
        }
    }

    // approve
    function approve(
        address spender,
        uint256 tokenIdOrValue
    ) public override returns (bool) {
        if (isValidTokenId(tokenIdOrValue)) {
            IERC721(erc721).approve(spender, tokenIdOrValue);
            return true;
        } else {
            return super.approve(spender, tokenIdOrValue);
        }
    }

    // ERC721 setApproveForAll
    function setApproveForAll(address operator, bool approved) public {
        IERC721(erc721).setApprovalForAll(operator, approved);
    }

    // ERC721 getApproved
    function getApproved(uint256 tokenId) public view returns (address) {
        return IERC721(erc721).getApproved(tokenId);
    }

    // ERC721 isApprovedForAll
    function isApprovedForAll(
        address _owner,
        address operator
    ) public view returns (bool) {
        return IERC721(erc721).isApprovedForAll(_owner, operator);
    }

    // ERC721 safeTransferFrom
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public {
        require(
            iERC721CheckAuth(erc721).isAuthorized(from, msg.sender, tokenId),
            "P404: not authorized"
        );
        IERC721(erc721).safeTransferFrom(from, to, tokenId, data);
        if (to == address(this)) {
            transform(tokenId);
        }
    }

    // ERC721 safeTransferFrom
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public {
        require(
            iERC721CheckAuth(erc721).isAuthorized(from, msg.sender, tokenId),
            "P404: not authorized"
        );
        IERC721(erc721).safeTransferFrom(from, to, tokenId);
        if (to == address(this)) {
            transform(tokenId);
        }
    }

    // ownerOf
    function ownerOf(uint256 tokenId) public view returns (address) {
        return IERC721(erc721).ownerOf(tokenId);
    }

    // token uri
    function tokenURI(uint256 tokenId) public view returns (string memory) {
        return IERC721Metadata(erc721).tokenURI(tokenId);
    }

    // IERC721Enumerable
    function totalSupplyERC721() public view returns (uint256) {
        return IERC721Enumerable(erc721).totalSupply();
    }

    // IERC721Enumerable
    function tokenOfOwnerByIndex(
        address _owner,
        uint256 index
    ) public view returns (uint256) {
        return IERC721Enumerable(erc721).tokenOfOwnerByIndex(_owner, index);
    }

    // IERC721Enumerable
    function tokenByIndex(uint256 index) public view returns (uint256) {
        return IERC721Enumerable(erc721).tokenByIndex(index);
    }

    function _erc20ToErc721(uint256 _amount) internal {
        // require(balanceOf(msg.sender) >= _amount, "P404: insufficient balance");
        require(_amount >= TRANSFORM_PRICE, "P404: insufficient amount");
        // can divide by TRANSFORM_PRICE
        require(_amount % TRANSFORM_PRICE == 0, "P404: invalid amount");

        uint256 nfts = _amount / TRANSFORM_PRICE;
        uint256 _realcost = nfts * TRANSFORM_PRICE;
        _burn(address(this), _realcost);
        for (uint256 i = 0; i < nfts; i++) {
            IERC721Mintable(erc721).mint(msg.sender);
        }
        emit FromTokenToNFT(msg.sender, _amount);
    }

    function _erc721ToErc20(uint256 _tokenId) internal {
        // require(ownerOf(_tokenId) == msg.sender, "P404: not owner");
        IERC721Burnable(erc721).burn(_tokenId);
        _mint(
            msg.sender,
            (TRANSFORM_PRICE * (10000 - TRANSFORM_LOSE_RATE)) / 10000
        );
        // _mint(address(0), (TRANSFORM_PRICE * TRANSFORM_LOSE_RATE) / 10000);
        emit FromNFTToToken(msg.sender, _tokenId);
    }

    function mint(address to, uint256 amount) public {
        require(msg.sender == erc721, "P404: only nft contract can mint");
        require(
            totalSupply() + amount <= MAX_SUPPLY,
            "P404: exceed max supply"
        );
        _mint(to, amount);
    }

    // onerc721received
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // supportsInterface
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IP404).interfaceId;
    }

    function mintNFT() public payable {
        require(msg.value >= MINT_PRICE, "P404: insufficient amount");
        require(tx.origin == msg.sender, "P404: not allow contract");
        // allowlist
        require(allowlist[msg.sender], "P404: not in allowlist");
        // require(!whoMinted[msg.sender], "p404: minted");
        require(msg.value <= MAX_MINT_VALUE, "P404: too much money, max is 0.6 ether");
        

        uint256 _mint = msg.value / MINT_PRICE;
        uint256 realcost = _mint * MINT_PRICE;

        require(mintedAmount[msg.sender] + realcost <= MAX_MINT_VALUE, "P404: exceed max mint value");
        require(nftMinted + _mint <= MAX_NFT_MINT, "P404: exceed max mint");

        for (uint256 i = 0; i < _mint; i++) {
            IERC721Mintable(erc721).mint(msg.sender);
        }

        emit PayToMint(msg.sender, realcost, _mint);
        nftMinted += _mint;
        mintedAmount[msg.sender] += realcost;

        // send to feeto
        if (feeTo != address(0)) {
            payable(feeTo).transfer(realcost);
        }

        uint256 refund = msg.value - realcost;
        if (refund > 0) {
            payable(msg.sender).transfer(refund);
        }
    }

    // redeive payable
    receive() external payable {
        mintNFT();
    }
}

