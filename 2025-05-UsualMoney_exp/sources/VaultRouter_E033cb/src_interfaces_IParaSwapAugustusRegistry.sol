// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

interface IParaSwapAugustusRegistry {
    function isValidAugustus(address augustus) external view returns (bool);
}
