// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Stepp2p is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Sale {
        address seller;
        uint256 totalAmount;
        uint256 remaining;
        uint256 receivedFee;
        uint256 sellFee;
        bool active;
    }

    mapping(uint256 => Sale) public sales;
    mapping(address => uint256[]) public sellerSales;
    mapping(address => uint256) public lastSellerSaleId;
    uint256 public lastSaleId;
    uint256 public sellFee;
    uint256 public buyFee;
    address public feeAccount;
    IERC20 public USDT;

    event SaleRegistered(uint256 saleId, address seller, uint256 amount);
    event SaleCanceled(uint256 saleId);
    event SalePartiallyCompleted(uint256 saleId, address buyer, uint256 amount);
    event SaleModifyed(
        uint256 saleId,
        address seller,
        uint256 totalAmount,
        uint256 remaining
    );

    constructor(
        uint256 _sellFee,
        uint256 _buyFee,
        address _feeAccount,
        address _usdt
    ) Ownable(msg.sender) {
        sellFee = _sellFee;
        buyFee = _buyFee;
        feeAccount = _feeAccount;
        USDT = IERC20(_usdt);
    }

    function setUSDT(address _usdt) external onlyOwner {
        USDT = IERC20(_usdt);
    }

    // 5% = 50
    function setSellFee(uint256 _sellFee) external onlyOwner {
        sellFee = _sellFee;
    }

    function setBuyFee(uint256 _buyFee) external onlyOwner {
        buyFee = _buyFee;
    }

    function setFeeAccount(address _feeAccount) external onlyOwner {
        feeAccount = _feeAccount;
    }

    function createSaleOrder(
        uint256 _amount
    ) external nonReentrant returns (uint256) {
        require(_amount > 0, "Amount must be greater than 0");
        lastSaleId++;

        USDT.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 feeAmount = sellFee > 0 ? (_amount * sellFee) / 1000 : 0;
        uint256 saleAmount = _amount - feeAmount;

        if (feeAmount > 0) {
            USDT.safeTransfer(feeAccount, feeAmount);
        }

        sales[lastSaleId] = Sale({
            seller: msg.sender,
            totalAmount: _amount,
            remaining: saleAmount,
            receivedFee: feeAmount,
            sellFee: sellFee,
            active: true
        });

        sellerSales[msg.sender].push(lastSaleId);
        lastSellerSaleId[msg.sender] = lastSaleId;

        emit SaleRegistered(lastSaleId, msg.sender, saleAmount);

        return lastSaleId;
    }

    function modifySaleOrder(
        uint256 _saleId,
        uint256 _modifyAmount,
        bool isPositive // true: add, false: sub
    ) external nonReentrant {
        require(_modifyAmount > 0, "Amount must be greater than 0");
        require(sales[_saleId].seller == msg.sender);

        uint256 feeAmount = sellFee > 0 ? (_modifyAmount * sellFee) / 1000 : 0;

        if (isPositive) {
            sales[_saleId].totalAmount += _modifyAmount;
            if (feeAmount > 0 && sales[_saleId].receivedFee > 0) {
                _modifyAmount -= feeAmount;
                sales[_saleId].receivedFee += feeAmount;
                USDT.safeTransfer(feeAccount, feeAmount);
            }
            sales[_saleId].remaining += _modifyAmount;
            USDT.safeTransferFrom(msg.sender, address(this), _modifyAmount);
        } else {
            require(
                sales[_saleId].remaining >= _modifyAmount,
                "Insufficient balance"
            );
            sales[_saleId].totalAmount -= _modifyAmount;
            sales[_saleId].remaining -= _modifyAmount;
            if (feeAmount > 0 && sales[_saleId].receivedFee > 0) {
                sales[_saleId].receivedFee -= feeAmount;
                USDT.safeTransferFrom(
                    feeAccount,
                    sales[_saleId].seller,
                    feeAmount
                );
            }
            USDT.safeTransfer(msg.sender, _modifyAmount);
        }

        emit SaleModifyed(
            _saleId,
            msg.sender,
            sales[_saleId].totalAmount,
            sales[_saleId].remaining
        );
    }

    function cancelSaleOrder(uint256 _saleId) external nonReentrant {
        Sale storage sale = sales[_saleId];
        require(
            sale.seller == msg.sender || msg.sender == owner(),
            "Not authorized"
        );
        require(sale.remaining > 0 && sale.active, "Invalid sale");

        uint256 refundAmount = sale.remaining;
        uint256 refundFeeAmount = sale.sellFee > 0
            ? (refundAmount * sale.sellFee) / 1000
            : 0;
        sale.active = false;

        if (refundFeeAmount > 0 && sale.receivedFee > 0) {
            USDT.safeTransferFrom(feeAccount, sale.seller, refundFeeAmount);
        }
        USDT.safeTransfer(sale.seller, refundAmount);
        emit SaleCanceled(_saleId);
    }

    function cancelSelectedSales(
        uint256[] calldata saleIds
    ) external nonReentrant {
        uint256 totalRefund = 0;
        uint256 totalRefundFee = 0;
        for (uint256 i = 0; i < saleIds.length; i++) {
            Sale storage sale = sales[saleIds[i]];
            require(sale.seller == msg.sender, "Not your sale");
            if (sale.active && sale.remaining > 0) {
                sale.active = false;
                totalRefund += sale.remaining;
                if (sale.receivedFee > 0) {
                    uint256 refundFee = (sale.remaining * sale.sellFee) / 1000;
                    totalRefundFee += refundFee;
                }

                emit SaleCanceled(saleIds[i]);
            }
        }
        if (totalRefund > 0) {
            if (totalRefundFee > 0) {
                USDT.safeTransferFrom(feeAccount, msg.sender, totalRefundFee);
            }
            USDT.safeTransfer(msg.sender, totalRefund);
        }
    }

    function cancelSelectedSales(
        address seller,
        uint256[] calldata saleIds
    ) external nonReentrant onlyOwner {
        uint256 totalRefund = 0;
        uint256 totalRefundFee = 0;
        for (uint256 i = 0; i < saleIds.length; i++) {
            Sale storage sale = sales[saleIds[i]];
            require(sale.seller == seller, "Not your sale");
            if (sale.active && sale.remaining > 0) {
                sale.active = false;
                totalRefund += sale.remaining;
                if (sale.receivedFee > 0) {
                    uint256 refundFee = (sale.remaining * sale.sellFee) / 1000;
                    totalRefundFee += refundFee;
                }
                emit SaleCanceled(saleIds[i]);
            }
        }
        if (totalRefund > 0) {
            if (totalRefundFee > 0) {
                USDT.safeTransferFrom(feeAccount, seller, totalRefundFee);
            }
            USDT.safeTransfer(seller, totalRefund);
        }
    }

    function cancelAllSales() external nonReentrant {
        uint256[] storage saleIds = sellerSales[msg.sender];
        uint256 totalRefund = 0;
        uint256 totalRefundFee = 0;
        for (uint256 i = 0; i < saleIds.length; i++) {
            Sale storage sale = sales[saleIds[i]];
            if (sale.active && sale.remaining > 0) {
                sale.active = false;
                totalRefund += sale.remaining;
                if (sale.receivedFee > 0) {
                    uint256 refundFee = (sale.remaining * sale.sellFee) / 1000;
                    totalRefundFee += refundFee;
                }
                emit SaleCanceled(saleIds[i]);
            }
        }

        if (totalRefund > 0) {
            if (totalRefundFee > 0) {
                USDT.safeTransferFrom(feeAccount, msg.sender, totalRefundFee);
            }
            USDT.safeTransfer(msg.sender, totalRefund);
        }
    }

    function cancelAllSales(address _seller) external nonReentrant onlyOwner {
        uint256[] storage saleIds = sellerSales[_seller];
        uint256 totalRefund = 0;
        uint256 totalRefundFee = 0;
        for (uint256 i = 0; i < saleIds.length; i++) {
            Sale storage sale = sales[saleIds[i]];
            if (sale.active && sale.remaining > 0) {
                sale.active = false;
                totalRefund += sale.remaining;
                if (sale.receivedFee > 0) {
                    uint256 refundFee = (sale.remaining * sale.sellFee) / 1000;
                    totalRefundFee += refundFee;
                }
                emit SaleCanceled(saleIds[i]);
            }
        }

        if (totalRefund > 0) {
            if (totalRefundFee > 0) {
                USDT.safeTransferFrom(feeAccount, _seller, totalRefundFee);
            }
            USDT.safeTransfer(_seller, totalRefund);
        }
    }

    function purchase(
        uint256 _saleId,
        uint256 _amount,
        address buyer
    ) external nonReentrant onlyOwner {
        Sale storage sale = sales[_saleId];
        require(sale.active, "Sale inactive");
        require(_amount > 0 && _amount <= sale.remaining, "Invalid amount");

        sale.remaining -= _amount;

        uint256 feeAmount = buyFee > 0 ? (_amount * buyFee) / 1000 : 0;
        uint256 saleAmount = _amount - feeAmount;
        if (feeAmount > 0) {
            USDT.safeTransfer(feeAccount, feeAmount);
        }

        USDT.safeTransfer(sale.seller, saleAmount);
        USDT.safeTransferFrom(sale.seller, buyer, saleAmount);

        if (sale.remaining == 0) {
            sale.active = false;
        }

        emit SalePartiallyCompleted(_saleId, buyer, _amount);
    }

    function purchase(
        uint256 _saleId,
        uint256 _amount,
        address buyer,
        address referrer
    ) external nonReentrant onlyOwner {
        Sale storage sale = sales[_saleId];
        require(sale.active, "Sale inactive");
        require(_amount > 0 && _amount <= sale.remaining, "Invalid amount");

        sale.remaining -= _amount;

        uint256 feeAmount = buyFee > 0 ? (_amount * buyFee) / 1000 : 0;
        uint256 saleAmount = _amount - feeAmount;
        if (feeAmount > 0) {
            USDT.safeTransfer(feeAccount, feeAmount);
        }

        USDT.safeTransfer(sale.seller, saleAmount);
        USDT.safeTransferFrom(sale.seller, buyer, saleAmount);
        USDT.safeTransferFrom(buyer, referrer, saleAmount);

        if (sale.remaining == 0) {
            sale.active = false;
        }

        emit SalePartiallyCompleted(_saleId, buyer, _amount);
    }

    function getTotalRemainingAmount(
        address _seller
    ) external view returns (uint256 totalRemaining) {
        uint256[] memory saleIds = sellerSales[_seller];
        for (uint256 i = 0; i < saleIds.length; i++) {
            Sale storage sale = sales[saleIds[i]];
            if (sale.active) {
                totalRemaining += sale.remaining;
            }
        }
    }

    function getRemainingSelectedAmount(
        uint256[] calldata saleIds
    ) external view returns (uint256 totalRemaining) {
        for (uint256 i = 0; i < saleIds.length; i++) {
            Sale storage sale = sales[saleIds[i]];
            if (sale.active) {
                totalRemaining += sale.remaining;
            }
        }
    }

    function emergencyWithdraw() external onlyOwner {
        uint256 amount = USDT.balanceOf(address(this));
        USDT.safeTransfer(owner(), amount);
    }
}
