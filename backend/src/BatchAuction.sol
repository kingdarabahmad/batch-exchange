// layout of contract
// version
// imports
// intefaces, libraries, contracts
// errors
// type declarations
// state variables
// Events
// modifiers
// functions

// Layout of functions:
// constructor
// recieve function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view and pure functions

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract BatchAuction is Ownable {
    /////////////////
    // Errors      //
    /////////////////
    error LessThanMinimumExecutionBlock();

    ///////////////////////////
    // State variables      //
    ///////////////////////////

    uint8 private constant MINIMUM_EXECUTION_BLOCKS = 10;

    IERC20 private immutable EXCHANGE_CURRENCY;

    address[] private markets;

    mapping(address => Market) public marketsData;
    mapping(address => Order[]) private currentOrders;
    mapping(address => Order[]) private pendingOrders;
    mapping(address => Order[]) private historicalOrders;

    enum OrderLocation {
        CurrentOrders,
        PendingOrders,
        MemoryOrders
    }

    enum OrderStatus {
        Pending,
        Active,
        PartiallyMatched,
        Matched,
        Expired,
        Cancelled
    }

    struct Order {
        address token;
        address user;
        uint256 quantity;
        uint256 price;
        bool isBuyOrder;
        OrderStatus status;
        uint256 createdAt;
        uint256 expiresAt;
        uint256 fulfilledAmount;
    }

    struct Market {
        uint8 minBlocks;
        bool status;
    }

    ///////////////////////////
    // Events                //
    ///////////////////////////
    event OrderExpired(Order indexed order);
    event MarketCannotBeExecuted(uint256 indexed minOrdersToExecuteMarket, uint256 indexed totalOrdersPresent);
    event OrdersExecutedForMarket(address indexed market, uint256 indexed clearingPrice);

    ////////////////
    // Modifiers  //
    ////////////////

    /////////////////
    // Functions   //
    /////////////////

    /////////////////
    // Constructor //
    /////////////////

    constructor(address _token) Ownable(msg.sender) {
        EXCHANGE_CURRENCY = IERC20(_token);
    }

    /////////////////////////////////////
    //  Public and External functions  //
    /////////////////////////////////////

    function createOrUpdateMarket(address _token, uint8 _minBlocks, bool _status) external onlyOwner {
        if (_minBlocks < MINIMUM_EXECUTION_BLOCKS) {
            revert LessThanMinimumExecutionBlock();
        }

        //create market data
        Market memory market = Market({minBlocks: _minBlocks, status: _status});

        //set market data correspond to token
        marketsData[_token] = market;

        //push token to markets array
        markets.push(_token);
    }

    function executeAllOrdersforAllMarkets() external {
        for (uint256 i = 0; i < markets.length; i++) {
            _executeAllOrdersForGivenMarket(markets[i]);
        }
    }

    ///////////////////////////////////////
    // Private and Internal Functions     //
    /////////////////////////////////////////

    function _executeAllOrdersForGivenMarket(address _marketId) internal {
        if (pendingOrders[_marketId].length < marketsData[_marketId].minBlocks) {
            while (currentOrders[_marketId].length > 0) {
                if (currentOrders[_marketId][0].expiresAt < block.timestamp) {
                    _expireOrder(_marketId, currentOrders[_marketId][0], OrderLocation.CurrentOrders);
                }
            }
            emit MarketCannotBeExecuted(marketsData[_marketId].minBlocks, pendingOrders[_marketId].length);
        }
        (Order[] memory buyOrders, Order[] memory sellOrders) = _transferAndSegregate(_marketId);

        //sort the orders
        buyOrders = _sortOrders(buyOrders, true);
        sellOrders = _sortOrders(sellOrders, false);

        //find clearing price
        uint256 clearingPrice = _findClearingPrice(buyOrders, sellOrders);

        (buyOrders, sellOrders) = _matchOrders(buyOrders, sellOrders, clearingPrice);

        _updateCurrentOrders(_marketId, buyOrders, sellOrders);

        emit OrdersExecutedForMarket(_marketId, clearingPrice);
    }

    function _expireOrder(address _marketId, Order memory _order, OrderLocation _orderLocation) internal {
        if (_order.status == OrderStatus.PartiallyMatched) {
            _changeStatusAndMoveToHistoricalData(_marketId, _order, OrderStatus.PartiallyMatched, _orderLocation);
        } else {
            _changeStatusAndMoveToHistoricalData(_marketId, _order, OrderStatus.Expired, _orderLocation);
        }

        emit OrderExpired(_order);
    }

    function _changeStatusAndMoveToHistoricalData(
        address _marketId,
        Order memory _order,
        OrderStatus _status,
        OrderLocation _orderLocation
    ) internal {
        uint256 i = 0;
        //remove order from the pending orders
        if (_orderLocation == OrderLocation.PendingOrders) {
            bool flag;
            for (i = 0; i < pendingOrders[_marketId].length; i++) {
                if (_compareOrders(pendingOrders[_marketId][i], _order)) {
                    pendingOrders[_marketId][i] = pendingOrders[_marketId][pendingOrders[_marketId].length - 1];
                    pendingOrders[_marketId].pop();
                    flag = true;
                    break;
                }
            }
            //remove order from the current order
        } else if (_orderLocation == OrderLocation.CurrentOrders) {
            bool flag;
            for (i = 0; i < currentOrders[_marketId].length; i++) {
                if (_compareOrders(currentOrders[_marketId][i], _order)) {
                    currentOrders[_marketId][i] = currentOrders[_marketId][currentOrders[_marketId].length - 1];
                    currentOrders[_marketId].pop();
                    flag = true;
                    break;
                }
            }
        }
        //if order is partially matched , then transfer the remaining amount to the user
        if (_status == OrderStatus.PartiallyMatched || _status == OrderStatus.Expired) {
            if (_order.isBuyOrder) {
                EXCHANGE_CURRENCY.transfer(_order.user, (_order.fulfilledAmount - _order.quantity) * _order.price);
            } else {
                IERC20(_order.token).transfer(_order.user, (_order.fulfilledAmount - _order.quantity));
            }
        }
        historicalOrders[_marketId].push(_order);
        historicalOrders[_marketId][historicalOrders[_marketId].length - 1].status = _status;
    }

    function _transferAndSegregate(address _marketId) internal returns (Order[] memory, Order[] memory) {
        uint256 totalCurrentOrders = currentOrders[_marketId].length;
        uint256 totalPendingOrders = pendingOrders[_marketId].length;

        uint256 totalBuyOrders;
        uint256 totalSellOrders;
        for (uint256 i = 0; i < totalCurrentOrders; i++) {
            if (currentOrders[_marketId][i].expiresAt > block.timestamp) {
                if (currentOrders[_marketId][i].isBuyOrder) {
                    totalBuyOrders++;
                } else {
                    totalSellOrders++;
                }
            }
        }
        for (uint256 i = 0; i < totalPendingOrders; i++) {
            if (pendingOrders[_marketId][i].expiresAt > block.timestamp) {
                if (pendingOrders[_marketId][i].isBuyOrder) {
                    totalBuyOrders++;
                } else {
                    totalSellOrders++;
                }
            }
        }

        Order[] memory buyOrders = new Order[](totalBuyOrders);
        Order[] memory sellOrders = new Order[](totalSellOrders);

        uint256 j;
        uint256 k;
        for (uint256 i = 0; i < totalCurrentOrders; i++) {
            if (currentOrders[_marketId][i].expiresAt <= block.timestamp) {
                _expireOrder(_marketId, currentOrders[_marketId][i], OrderLocation.CurrentOrders);
            } else if (currentOrders[_marketId][i].isBuyOrder) {
                buyOrders[j] = currentOrders[_marketId][i];
                j++;
            } else {
                sellOrders[k] = currentOrders[_marketId][i];
                k++;
            }
        }

        while (pendingOrders[_marketId].length > 0) {
            if (pendingOrders[_marketId][0].expiresAt <= block.timestamp) {
                _expireOrder(_marketId, pendingOrders[_marketId][0], OrderLocation.PendingOrders);
            } else {
                pendingOrders[_marketId][0].status = OrderStatus.Active;
                currentOrders[_marketId].push(pendingOrders[_marketId][0]);
                if (pendingOrders[_marketId][0].isBuyOrder) {
                    buyOrders[j] = pendingOrders[_marketId][0];
                    j++;
                } else {
                    sellOrders[k] = pendingOrders[_marketId][0];
                    k++;
                }
            }
            if (pendingOrders[_marketId].length > 0) {
                pendingOrders[_marketId][0] = pendingOrders[_marketId][pendingOrders[_marketId].length - 1];
                pendingOrders[_marketId].pop();
            }
        }
        return (buyOrders, sellOrders);
    }

    function _findClearingPrice(Order[] memory _buyOrders, Order[] memory _sellOrders)
        internal
        pure
        returns (uint256)
    {
        uint256 i = 0;
        uint256 j = 0;
        uint256 cummulativeDemand = 0;
        uint256 cummulativeSupply = 0;

        while (i < _buyOrders.length && j < _sellOrders.length) {
            if (_buyOrders[i].price >= _sellOrders[j].price) {
                cummulativeDemand += _buyOrders[i].quantity;
                cummulativeSupply += _sellOrders[j].quantity;

                if (cummulativeDemand >= cummulativeSupply) {
                    return _sellOrders[j].price;
                }
                j++;
            } else {
                i++;
            }
        }
        return 0;
    }

    function _matchOrders(Order[] memory _buyOrders, Order[] memory _sellOrders, uint256 _clearingPrice)
        internal
        returns (Order[] memory, Order[] memory)
    {
        uint256 i = 0;
        uint256 j = 0;

        while (i < _buyOrders.length && j < _sellOrders.length) {
            if (_buyOrders[i].price >= _clearingPrice && _sellOrders[j].price <= _clearingPrice) {
                uint256 tradeQuantity = (_buyOrders[i].quantity - _buyOrders[i].fulfilledAmount)
                    < (_sellOrders[j].quantity - _sellOrders[j].fulfilledAmount)
                    ? _buyOrders[i].quantity - _buyOrders[i].fulfilledAmount
                    : _sellOrders[j].quantity - _sellOrders[j].fulfilledAmount;

                _buyOrders[i].fulfilledAmount += tradeQuantity;
                _buyOrders[i].status = OrderStatus.PartiallyMatched;

                _sellOrders[j].fulfilledAmount += tradeQuantity;
                _sellOrders[j].status = OrderStatus.PartiallyMatched;

                //exchange the tokens
                IERC20(_buyOrders[i].token).transfer(_buyOrders[i].user, tradeQuantity);
                EXCHANGE_CURRENCY.transfer(_sellOrders[j].user, tradeQuantity * _clearingPrice);

                if (_buyOrders[i].fulfilledAmount == _buyOrders[i].quantity) {
                    _buyOrders[i].status = OrderStatus.Matched;
                    i++;
                }

                if (_sellOrders[j].fulfilledAmount == _sellOrders[j].quantity) {
                    _sellOrders[j].status = OrderStatus.Matched;
                    j++;
                }
            } else {
                if (_buyOrders[i].price < _clearingPrice) {
                    i++;
                } else if (_sellOrders[j].price > _clearingPrice) {
                    j++;
                }
            }
        }
        return (_buyOrders, _sellOrders);
    }

    function _updateCurrentOrders(address _marketId, Order[] memory _buyOrders, Order[] memory _sellOrders) internal {
        _buyOrders = _sortOrdersByCreatedAt(_buyOrders, false);
        _sellOrders = _sortOrdersByCreatedAt(_sellOrders, false);

        while (currentOrders[_marketId].length > 0) {
            currentOrders[_marketId].pop();
        }
        uint256 j;
        uint256 i;
        while (i < _buyOrders.length && j < _sellOrders.length) {
            if (_buyOrders[i].createdAt <= _sellOrders[j].createdAt) {
                if (_buyOrders[i].status == OrderStatus.Matched) {
                    _changeStatusAndMoveToHistoricalData(
                        _marketId, _buyOrders[i], OrderStatus.Matched, OrderLocation.MemoryOrders
                    );
                } else if (_buyOrders[i].expiresAt <= block.timestamp) {
                    _expireOrder(_marketId, _buyOrders[i], OrderLocation.MemoryOrders);
                } else {
                    currentOrders[_marketId].push(_buyOrders[i]);
                }
                i++;
            } else {
                if (_sellOrders[j].status == OrderStatus.Matched) {
                    _changeStatusAndMoveToHistoricalData(
                        _marketId, _sellOrders[j], OrderStatus.Matched, OrderLocation.MemoryOrders
                    );
                } else if (_sellOrders[j].expiresAt <= block.timestamp) {
                    _expireOrder(_marketId, _sellOrders[j], OrderLocation.MemoryOrders);
                } else {
                    currentOrders[_marketId].push(_sellOrders[j]);
                }
                j++;
            }
        }
        if (i < _buyOrders.length) {
            for (uint256 x = i; x < _buyOrders.length; x++) {
                if (_buyOrders[x].status == OrderStatus.Matched) {
                    _changeStatusAndMoveToHistoricalData(
                        _marketId, _buyOrders[x], OrderStatus.Matched, OrderLocation.MemoryOrders
                    );
                } else if (_buyOrders[x].expiresAt <= block.timestamp) {
                    _expireOrder(_marketId, _buyOrders[x], OrderLocation.MemoryOrders);
                } else {
                    currentOrders[_marketId].push(_buyOrders[x]);
                }
            }
        } else if (j < _sellOrders.length) {
            for (uint256 x = j; x < _sellOrders.length; x++) {
                if (_sellOrders[x].status == OrderStatus.Matched) {
                    _changeStatusAndMoveToHistoricalData(
                        _marketId, _sellOrders[x], OrderStatus.Matched, OrderLocation.MemoryOrders
                    );
                } else if (_sellOrders[x].expiresAt <= block.timestamp) {
                    _expireOrder(_marketId, _sellOrders[x], OrderLocation.MemoryOrders);
                } else {
                    currentOrders[_marketId].push(_sellOrders[x]);
                }
            }
        }
    }

    ////////////////////////////////////////////
    // Public and External view Functions     //
    ///////////////////////////////////////////

    ////////////////////////////////////////////////////
    // Private and Internal view and pure Functions   //
    ////////////////////////////////////////////////////

    function _compareOrders(Order memory _order1, Order memory _order2) internal pure returns (bool) {
        if (_order1.user != _order2.user) {
            return false;
        }

        if (_order1.token != _order2.token) {
            return false;
        }

        if (_order1.createdAt != _order2.createdAt) {
            return false;
        }

        if (_order1.expiresAt != _order2.expiresAt) {
            return false;
        }
        return true;
    }

    function _sortOrders(Order[] memory _orders, bool _isDesc) internal pure returns (Order[] memory) {
        if (_orders.length > 0) {
            _orders = _quickSort(_orders, 0, _orders.length - 1, "price", _isDesc);
        }

        return _orders;
    }

    function _sortOrdersByCreatedAt(Order[] memory _orders, bool _isDesc) internal pure returns (Order[] memory) {
        if (_orders.length > 0) {
            _orders = _quickSort(_orders, 0, _orders.length - 1, "createdAt", _isDesc);
        }

        return _orders;
    }

    function _quickSort(Order[] memory _orders, uint256 _low, uint256 _high, string memory _key, bool _isDesc)
        internal
        pure
        returns (Order[] memory)
    {
        if (_low < _high) {
            uint256 pivotVal = _getOrderValueByKey(_orders[(_low + _high) / 2], _key);

            uint256 low1 = _low;
            uint256 high1 = _high;
            for (;;) {
                if (_isDesc) {
                    while (_getOrderValueByKey(_orders[low1], _key) > pivotVal) {
                        low1++;
                    }
                    while (_getOrderValueByKey(_orders[high1], _key) < pivotVal) {
                        high1--;
                    }
                } else {
                    while (_getOrderValueByKey(_orders[low1], _key) < pivotVal) {
                        low1++;
                    }
                    while (_getOrderValueByKey(_orders[high1], _key) > pivotVal) {
                        high1--;
                    }
                }
                if (low1 >= high1) break;
                (_orders[low1], _orders[high1]) = (_orders[high1], _orders[low1]);
                low1++;
                high1--;
            }
            if (_low < high1) _orders = _quickSort(_orders, _low, high1, _key, _isDesc);
            high1++;
            if (high1 < _high) _orders = _quickSort(_orders, high1, _high, _key, _isDesc);
        }

        return _orders;
    }

    function _getOrderValueByKey(Order memory order, string memory key) private pure returns (uint256) {
        if (keccak256(bytes(key)) == keccak256("createdAt")) {
            return order.createdAt;
        } else if (keccak256(bytes(key)) == keccak256("price")) {
            return order.price;
        }
        return 0;
    }
}
