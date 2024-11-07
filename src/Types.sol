// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

enum Side {
    Bull,
    Bear,
    Both
}

struct Position {
    uint256 bullAmount;
    uint256 bearAmount;
    bool collected;
}

struct PredictionMarket {
    bytes32 id;
    PoolId pool;
    uint256 endTime;
    uint256 liquidity;
    uint256 balanceBull;
    uint256 balanceBear;
    uint256 openPrice;
    uint256 closePrice;
    uint256 fees;
    uint256 closingBullValue;
    uint256 closingBearValue;
    bool settled;
}

struct PoolInfo {
    PoolKey pool;
    uint256 lastActivityBlock;
    bool registered;
}
