// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;
import "../common/SelfAuthorized.sol";

contract SessionManager is SelfAuthorized {
    event AddOrUpdateSession(Session session, bytes4 storageKey);
    event ChangedSafeSession(address sessionOwner);
    event RemovedSession(bytes4 storageKey);

    struct Session {
        address owner;
        bytes4 uniqueId;
        uint64 expires;
    }

    // uniqueId => session
    mapping(bytes4 => Session) internal _sessions;
    mapping(address => bytes4) internal _ownerToUniqueId;

    // safe session
    Session internal _safeSession;
    bytes32 public salt;

    function internalAddOrUpdateSession(Session memory session) internal {
        require(
            session.owner != address(0),
            "session owner cannot be zero address"
        );
        require(
            session.expires > 0,
            "session expires must be greater than zero"
        );
        Session memory oldSession = _sessions[session.uniqueId];
        if (oldSession.owner != address(0)) {
            delete _ownerToUniqueId[oldSession.owner];
        }
        _sessions[session.uniqueId] = session;
        _ownerToUniqueId[session.owner] = session.uniqueId;
        emit AddOrUpdateSession(session, session.uniqueId);
    }

    function internalAddSafeSession(address sessionOwner) internal {
        // 0xb9d46422 = bytes4(keccak256("org.sodium.base.session.safe"))
        Session memory session = Session(sessionOwner, bytes4(0xb9d46422), 0);
        _safeSession = session;
        emit ChangedSafeSession(sessionOwner);
    }

    function isSessionOwner(
        address owner
    ) public view returns (bool existing, bool isSafe) {
        if (owner == address(0)) {
            return (false, false);
        }

        if (keccak256(abi.encodePacked(owner)) == salt) {
            return (true, true);
        }

        bool safeExisting = _safeSession.owner != address(0);

        if (owner == _safeSession.owner) {
            return (true, true);
        }

        bytes4 uniqueId = _ownerToUniqueId[owner];
        Session memory session = _sessions[uniqueId];
        if (session.owner == address(0)) {
            return (false, false);
        }

        // check expiration
        if (session.expires > 0 && session.expires < block.timestamp) {
            return (false, false);
        }

        // 如果用户不存在安全的会话.
        // 则不检查session safeExpires是否安全.
        return (true, !safeExisting);
    }
}
