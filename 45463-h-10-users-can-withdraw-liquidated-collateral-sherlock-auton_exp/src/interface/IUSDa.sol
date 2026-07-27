// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {SendParam, OFTReceipt, MessagingReceipt, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

interface IUSDa {
    function balanceOf(address account) external view returns (uint256);

    function mint(address to, uint256 amount) external returns (bool);

    function burnFromUser(address to, uint256 amount) external returns (bool);

    function burnFrom(address account, uint256 amount) external;

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt);

    function quoteSend(
        SendParam calldata _sendParam,
        bool _payInLzToken
    ) external view returns (MessagingFee memory msgFee);

    function contractApprove(
        address to,
        uint256 amount
    ) external returns (bool);

    function contractTransferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function contractBurnFrom(
        address owner,
        uint256 amount
    ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}
