pragma solidity ^0.8.20;
contract DarkpoolFrozen {
    error DarkpoolFrozenError();

    fallback() external payable {
        revert DarkpoolFrozenError();
    }

    receive() external payable {
        revert DarkpoolFrozenError();
    }
}