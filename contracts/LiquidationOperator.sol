//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.17;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// // https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// // https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
// interface IERC20 {
//     // Returns the account balance of another account with address _owner.
//     function balanceOf(address owner) external view returns (uint256);

//     /**
//      * Allows _spender to withdraw from your account multiple times, up to the _value amount.
//      * If this function is called again it overwrites the current allowance with _value.
//      * Lets msg.sender set their allowance for a spender.
//      **/
//     function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

//     /**
//      * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
//      * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
//      * Lets msg.sender send pool tokens to an address.
//      **/
//     function transfer(address to, uint256 value) external returns (bool);
// }

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    using SafeERC20 for IERC20;

    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    //    *** Your code here ***
    // Owner of this contract
    address public owner;

    // The lending pool the liquidator repay and get the collateral (Aave Lending Pool V2)
    ILendingPool public i_lending_pool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    // The Uniswap factory
    IUniswapV2Factory public uniswap_factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IUniswapV2Factory public sushiswap_factory = IUniswapV2Factory(0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac);
    bool is_use_sushi_swap = false;
    
    // Tokens used in this liquidation
    address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address WISE = 0x66a0f676479Cee1d7373f3DC2e2952778BfF5bd6;
    address PEPE = 0x6982508145454Ce325dDbE47a25d4ec3d2311933;
    address PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;

    // Target user address and variable
    address target_user = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    uint256 debt_to_cover = 2916378221684;
    uint256 minus = 1125153682733;
    uint256 minus_wbtc = 0;

    address[][] pairs;
    uint256[][] reserve_changes;
    address[][] best_routes;
    uint256[] best_amounts;

    uint256 expected_health_factor = 10 ** health_factor_decimals;
    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        owner = msg.sender;
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    //   *** Your code here ***
    receive() external payable {}

    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***
        require(msg.sender == owner, "Only owner can trigger");

        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        // check whether the user's health factor is below 1
        (,,,,,uint256 health_factor) = i_lending_pool.getUserAccountData(target_user);
        require(health_factor < expected_health_factor, "The target address is not liquidatable");

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***
        // // dfs to find the route that maximise the profit
        // address[] memory avail_token = new address[](4);
        // avail_token[0] = WETH;
        // avail_token[1] = USDC;
        // avail_token[2] = WBTC;
        // avail_token[3] = DAI;
        // address[] memory best_route = new address[](0);

        // uint256 total = 0;
        // address token_in_sim = USDT;
        // address target_token_sim = WETH;
        // uint256 amount_sim =   2925153682733;
        // uint256 increase_sim =  525153682733;
        // bool is_reverse = true;

        // is_use_sushi_swap = false;

        // // calculate best routes to convert WBTC to USDT
        // simulate(avail_token, token_in_sim, target_token_sim, amount_sim, increase_sim, is_reverse);
        // for (uint i=0; i<best_routes.length; i++) {
        //     string memory route_str = convert_route_to_string(token_in_sim, best_routes[i], is_reverse);
        //     console.log(route_str);
        //     console.log(best_amounts[i]);
        //     total += best_amounts[i];
        //     console.log();
        // }

        // console.log("Total: ", total);
        // console.log();

        is_use_sushi_swap = true;

        address flash_in_flash_out;
        
        if (is_use_sushi_swap) {
            flash_in_flash_out = sushiswap_factory.getPair(WETH, USDT);
        } else {
            flash_in_flash_out = uniswap_factory.getPair(WETH, USDT);
        }

        IUniswapV2Pair flash_pair = IUniswapV2Pair(flash_in_flash_out);
        uint256 token_in_reserve = 0;
        uint256 token_out_reserve = 0;

        // call the flash loan here with data size != 0
        if(flash_pair.token0() == USDT) {
            // (token_out_reserve, token_in_reserve,) = flash_pair.getReserves();
            flash_pair.swap(debt_to_cover, 0, address(this), bytes("flash loan"));
        } else {
            // (token_in_reserve, token_out_reserve,) = flash_pair.getReserves();
            flash_pair.swap(0, debt_to_cover, address(this), bytes("flash loan"));
        }

        // 3. Convert the profit into ETH and send back to sender
        //    *** Your code here ***
        // The remaining WBTC is the profit
        uint256 weth_bal = IERC20(WETH).balanceOf(address(this));

        // withdraw the WETH to ETH
        IWETH(WETH).withdraw(weth_bal);

        // Ensure the contract has enough ETH as required
        require(address(this).balance >= weth_bal, "Not enough ETH");

        // Send ETH to the caller/owner
        (bool success, ) = msg.sender.call{value: weth_bal}("");
        require(success, "ETH transfer failed");

        // END TODO
    }

    // match address to token name
    function match_address_name_str (address token) internal view returns (string memory) {
        if(token == WBTC) {
            return "WBTC";
        } else if(token == WETH) {
            return "WETH";
        } else if(token == USDT) {
            return "USDT";
        } else if(token == USDC) {
            return "USDC";
        } else if(token == DAI) {
            return "DAI";
        } else if(token == PAXG) {
            return "PAXG";
        }

        return "None";
    }

    // printing the routes
    function convert_route_to_string(address token_start, address[] memory route, bool is_reverse) internal view returns (string memory) {
        string memory route_str;
        
        if (is_reverse) {
            for (uint i=route.length; i>0; i--){
                route_str = string.concat(route_str, match_address_name_str(route[i-1]));
                route_str = string.concat(route_str, "->");
            }

            route_str = string.concat(route_str, match_address_name_str(token_start));

        } else {
            route_str = match_address_name_str(token_start);

            for (uint i=0; i<route.length; i++){
                route_str = string.concat(route_str, "->");
                route_str = string.concat(route_str, match_address_name_str(route[i]));
            }
        }
        
        return route_str;
    }

    // check whether 2 array is identical
    function array_is_same (address[] memory arr_0, address[] memory arr_1) internal view returns (bool) {
        if (arr_0.length > arr_1.length || arr_0.length < arr_1.length) {
            return false;
        }else {
            for (uint i=0; i<arr_0.length; i++) {
                if (arr_0[i] != arr_1[i]) {
                    return false;
                }
            }
        }

        return true;
    }

    // update the cummulative reserve changes from the previous runs during simulation
    function update_reserves (address[] memory cur_best_route, uint256[][] memory cur_token_ins_outs, address token_in, bool is_reverse) internal {
        for (uint j=0; j<cur_best_route.length; j++) {
            if(j == 0) {
                if (is_reverse) {
                    update_reserve(cur_best_route[j], token_in, cur_token_ins_outs[j]);
                } else {
                    update_reserve(token_in, cur_best_route[j], cur_token_ins_outs[j]);
                }
            } else {
                if (is_reverse) {
                    update_reserve(cur_best_route[j], cur_best_route[j-1], cur_token_ins_outs[j]);
                } else {
                    update_reserve(cur_best_route[j-1], cur_best_route[j], cur_token_ins_outs[j]);
                }
                
            }
        }
    }

    // simulate the best route to exchange the token that maximise the profits
    function simulate(address[] memory avail_token, address token_in, address target_token, uint256 amount, uint256 increase, bool is_reverse) internal {        
        uint256 runs = amount/increase;

        // split the simulation in multiple runs to find the best route for each run
        for (uint i=0; i<=runs; i++) {
            if(i == runs) {
                if (amount - (increase*runs) <=0 ){
                    break;
                }
                increase = amount - (increase*runs);
            }

            address[] memory route = new address[](0);
            uint256[][] memory token_ins_outs = new uint256[][](0);
            
            PathInput memory input = PathInput(
                target_token,
                token_in,
                token_in,
                increase,
                route,
                avail_token,
                token_ins_outs,
                is_reverse
            );

            // dfs
            (address[] memory cur_best_route, uint256[][] memory cur_token_ins_outs, uint256 cur_best_amount) = calculate_best_path(input);

            // increase the token_in and decrease the token_out in the pool reserve
            update_reserves(cur_best_route, cur_token_ins_outs, token_in, is_reverse);
            
            // store/update the best routes so far
            if (best_routes.length == 0) {
                address[] storage newRoute = best_routes.push();

                for (uint j = 0; j < cur_best_route.length; j++) {
                    newRoute.push(cur_best_route[j]);
                }

                best_amounts.push(cur_best_amount);
            } else {
                bool route_found = false;

                for (uint j=0; j<best_routes.length; j++) {
                    if(array_is_same(best_routes[j], cur_best_route)) {
                        best_amounts[j] += cur_best_amount;
                        route_found = true;
                        break;
                    }
                }

                if (!route_found) {
                    address[] storage newRoute = best_routes.push();

                    for (uint j = 0; j < cur_best_route.length; j++) {
                        newRoute.push(cur_best_route[j]);
                    }

                    best_amounts.push(cur_best_amount);
                }
            }
        }
    }

    struct PathInput {
        address target_token;
        address token_in;
        address token_out;
        uint256 amount;
        address[] cur_route;
        address[] avail_token;
        uint256[][] token_ins_outs;
        // uint256[] token_outs;
        bool is_reverse;
    }

    // update the route of current loop for the next recursive call
    function copy_route (address[] memory old_route, address next_token) internal returns (address[] memory) {
        address[] memory new_route = new address[](old_route.length + 1);

        for(uint j = 0; j < old_route.length; j++) {
            new_route[j] = old_route[j];
        }

        new_route[old_route.length] = next_token;

        return new_route;
    }

    // extend the array that store the reserve changes of the current recursive call
    function copy_token_amount (uint256[][] memory token_ins_outs) internal returns (uint256[][] memory) {
        uint256[][] memory new_token_ins_outs = new uint256[][](token_ins_outs.length + 1);

        for(uint j = 0; j < token_ins_outs.length; j++) {
            uint256[] memory ins_outs = new uint256[](token_ins_outs[j].length);
            
            for(uint k=0; k<token_ins_outs[j].length; k++) {
                ins_outs[k] = token_ins_outs[j][k];
            }

            new_token_ins_outs[j] = ins_outs;
        }

        uint256[] memory last_ins_outs = new uint256[](2);
        last_ins_outs[0] = 0;
        last_ins_outs[1] = 0;
        new_token_ins_outs[token_ins_outs.length] = last_ins_outs;

        return new_token_ins_outs;
    }

    // update the array that store the token available for next recursive call
    function modify_avail_tokens (address[] memory avail_token, uint i) internal returns (address[] memory){
        address[] memory new_avail_token = new address[](avail_token.length - 1);

        uint idx = 0;
        
        for(uint j = 0; j < avail_token.length; j++) {
            if(j != i){
                new_avail_token[idx] = avail_token[j];
                idx++;
            }
        }

        return new_avail_token;
    }

    // find the minimum amount in by given the amount out and a list of token that can be swapped
    function calculate_best_path(PathInput memory input) internal returns (address[] memory, uint256[][] memory, uint256) {
        if(input.token_in != input.token_out) {
            // if this is call by this function itself, calculate the amount in or out for current swap pair
            if (input.is_reverse) {
                input.amount = get_swap_in(input.amount, input.token_in, input.token_out, true);
                input.token_ins_outs[input.token_ins_outs.length-1][0] = input.amount;
            } else {
                input.amount = get_swap_out(input.amount, input.token_in, input.token_out, true);
                input.token_ins_outs[input.token_ins_outs.length-1][1] = input.amount;
            }

            // if the token in is the target token, stop here
            if( (input.is_reverse && input.token_in == input.target_token) ||
            (!input.is_reverse && input.token_out == input.target_token) ) {
                return (input.cur_route, input.token_ins_outs, input.amount);
            }
        }

        address[] memory best_route;
        uint256[][] memory best_token_ins_outs;
        uint256 best_amount = 0;

        // start dfs, select a token from the available token list and compute the amount in require
        for(uint i = 0; i < input.avail_token.length; i++) {
            // new route
            address[] memory new_route = copy_route(input.cur_route, input.avail_token[i]);

            // new token ins
            (uint256[][] memory new_token_ins_outs) = copy_token_amount(input.token_ins_outs);

            // new available token array
            address[] memory new_avail_token = modify_avail_tokens(input.avail_token, i);

            PathInput memory nextInput;

            if (input.is_reverse) {
                new_token_ins_outs[new_token_ins_outs.length-1][0] = 0;
                new_token_ins_outs[new_token_ins_outs.length-1][1] = input.amount;

                nextInput = PathInput(
                    input.target_token,
                    input.avail_token[i],
                    input.token_in,
                    input.amount,
                    new_route,
                    new_avail_token,
                    new_token_ins_outs,
                    input.is_reverse
                );

            }else {
                new_token_ins_outs[new_token_ins_outs.length-1][0] = input.amount;
                new_token_ins_outs[new_token_ins_outs.length-1][1] = 0;

                nextInput = PathInput(
                    input.target_token,
                    input.token_out,
                    input.avail_token[i],
                    input.amount,
                    new_route,
                    new_avail_token,
                    new_token_ins_outs,
                    input.is_reverse
                );
            }

            // recursive call
            (address[] memory cur_best_route, uint256[][] memory cur_token_ins_outs, uint256 cur_best_amount) = calculate_best_path(nextInput);

            // update the route and min amount in
            if((best_amount == 0 && cur_best_amount > 0) || (input.is_reverse && cur_best_amount > 0 && cur_best_amount < best_amount) ||
            (!input.is_reverse && cur_best_amount > 0 && cur_best_amount > best_amount)){
                best_route = cur_best_route;
                best_token_ins_outs = cur_token_ins_outs;
                best_amount = cur_best_amount;
            }
        }

        // return the best route
        return (best_route, best_token_ins_outs, best_amount);
    }

    function update_reserve(address token_in, address token_out, uint256[] memory amount_in_out) internal {
        bool is_found = false;
        
        for (uint i=0; i<pairs.length; i++) {
            if(pairs[i][0] == token_in && pairs[i][1] == token_out) {
                reserve_changes[i][0] += amount_in_out[0];
                reserve_changes[i][1] += amount_in_out[1];
                is_found = true;
                break;
            }
        }

        if (!is_found) {
            address[] storage new_pair = pairs.push();
            uint256[] storage new_reserve_change = reserve_changes.push();
            new_pair.push(token_in);
            new_pair.push(token_out);
            new_reserve_change.push(amount_in_out[0]);
            new_reserve_change.push(amount_in_out[1]);
        }
    }

    function calculate_latest_reserve(address token_in, address token_out, uint256 reserve_in, uint256 reserve_out, bool is_reverse) internal view returns (uint256, uint256) {
        for (uint i=0; i<pairs.length; i++) {
            if(pairs[i][0] == token_in && pairs[i][1] == token_out) {
                if (reserve_changes[i][1] > reserve_out) {
                    reserve_out = 0;
                } else {
                    reserve_in += reserve_changes[i][0]; 
                    reserve_out -= reserve_changes[i][1];
                }

                return (reserve_in, reserve_out);
            }
        }

        return (reserve_in, reserve_out);
    }

    function get_swap_in(uint256 amount_out, address token_in, address token_out, bool is_simulate) internal view returns (uint256) {
        address token_in_out; 
        
        if(is_use_sushi_swap) {
            token_in_out = sushiswap_factory.getPair(token_in, token_out);
        } else {
            token_in_out = uniswap_factory.getPair(token_in, token_out);
        }

        IUniswapV2Pair pair = IUniswapV2Pair(token_in_out);
        uint256 token_in_reserve = 0;
        uint256 token_out_reserve = 0;
        uint256 amount_in = 0;

        // cannot find the pair
        if (token_in_out == address(0)) {
            return 0;
        }

        // get token reserve
        if(pair.token0() == token_in) {
            (token_in_reserve, token_out_reserve,) = pair.getReserves();
        } else {
            (token_out_reserve, token_in_reserve,) = pair.getReserves();
        }

        if (is_simulate) {
            // use the latest reverse changes to update the pool reserve
            (token_in_reserve, token_out_reserve) = calculate_latest_reserve(token_in, token_out, token_in_reserve, token_out_reserve, true);
        }
        
        // if there is not enough token, return 0
        if(token_out_reserve < amount_out) {
            return amount_in;
        }

        // calculate the amount_out
        if(amount_out > 0) {
            amount_in = getAmountIn(amount_out, token_in_reserve, token_out_reserve);
        }

        return amount_in;
    }

    function get_swap_out(uint256 amount_in, address token_in, address token_out, bool is_simulate) internal returns (uint256) {
        address token_in_out; 
        
        if(is_use_sushi_swap) {
            token_in_out = sushiswap_factory.getPair(token_in, token_out);
        } else {
            token_in_out = uniswap_factory.getPair(token_in, token_out);
        }

        IUniswapV2Pair pair = IUniswapV2Pair(token_in_out);
        uint256 token_in_reserve = 0;
        uint256 token_out_reserve = 0;
        uint256 amount_out = 0;

        // cannot find the pair
        if (token_in_out == address(0)) {
            return 0;
        }

        // get token reserve
        if(pair.token0() == token_in) {
            (token_in_reserve, token_out_reserve,) = pair.getReserves();
        } else {
            (token_out_reserve, token_in_reserve,) = pair.getReserves();
        }

        if (is_simulate) {
            // use the latest reverse changes to update the pool reserve
            (token_in_reserve, token_out_reserve) = calculate_latest_reserve(token_in, token_out, token_in_reserve, token_out_reserve, false);
        }
        
        if(token_out_reserve <= 0) {
            return 0;
        }

        // calculate the amount_out
        if(amount_in > 0) {
            amount_out = getAmountOut(amount_in, token_in_reserve, token_out_reserve);
        }

        return amount_out;
    }

    function swap_pair (address token_in, address token_out, uint256 amount_in, uint256 amount_out) internal {
        address token_in_token_out; 
        
        if(is_use_sushi_swap) {
            token_in_token_out = sushiswap_factory.getPair(token_in, token_out);
        } else {
            token_in_token_out = uniswap_factory.getPair(token_in, token_out);
        }

        IUniswapV2Pair pair = IUniswapV2Pair(token_in_token_out);

        // transfer token_in to the swap pool
        IERC20(token_in).safeTransfer(token_in_token_out, amount_in);

        // swap
        if(pair.token0() == token_out) {
            pair.swap(amount_out, 0, address(this), bytes(""));
        } else {
           pair.swap(0, amount_out, address(this), bytes(""));
        }
    }

    // swap WBTC->WETH->USDT
    function swap_weth (uint256 amount_owed, uint256 wbtc_bal) internal {
        // get the pair to do the swap
        // swap WBTC->WETH
        uint256 to_swap = wbtc_bal;
        uint256 to_received = 0;
        address token_in = WBTC;

        uint256 weth_to_recv = get_swap_out(wbtc_bal-minus_wbtc, WBTC, WETH, false);
        swap_pair(WBTC, WETH, wbtc_bal-minus_wbtc, weth_to_recv);

        if (minus_wbtc > 0) {
            is_use_sushi_swap = false;
            weth_to_recv = get_swap_out(minus_wbtc, WBTC, WETH, false);
            swap_pair(WBTC, WETH, minus_wbtc, weth_to_recv);
        }
       
        uint256 weth_bal = IERC20(WETH).balanceOf(address(this));
        console.log("WETH: ", weth_bal);

        // start swapping the WETH to USDT using uniswap
        // route WETH->USDT
        is_use_sushi_swap = false;
        uint256 swap0 = amount_owed - minus;
        uint256 weth_to_swap = get_swap_in(swap0, WETH, USDT, false);
        swap_pair(WETH, USDT, weth_to_swap, swap0);

        if (minus > 0) {
            // route WETH->USDC->USDT
            uint256 usdc_to_swap = get_swap_in(minus, USDC, USDT, false);
            weth_to_swap =  get_swap_in(usdc_to_swap, WETH, USDC, false);
            swap_pair(WETH, USDC, weth_to_swap, usdc_to_swap);
            swap_pair(USDC, USDT, usdc_to_swap, minus);
        }
        
    }

    // required by the swap
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
        //    *** Your code here ***
        require(sender == address(this), "Unauthorized flash loan sender");

        // 2.1 liquidate the target user
        //    *** Your code here ***
        // approve the lending pool to get token from this address
        IERC20(USDT).safeApprove(address(i_lending_pool), debt_to_cover);

        // call liquidation function
        i_lending_pool.liquidationCall(
            WBTC,
            USDT,
            target_user,
            debt_to_cover,
            false
        );

        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***
        // calculate the amount owed (flash loan amount + 0.3%)
        uint256 amount_owed = debt_to_cover * 1000 / 997 + 1;
        console.log("Amount (USDT) Owed: ", amount_owed);

        // get how much WBTC collateral we claimed
        uint256 wbtc_bal = IERC20(WBTC).balanceOf(address(this));
        console.log("Collateral (WBTC) claimed: ", wbtc_bal);
        require(wbtc_bal > 0, "The balance of WBTC is below 0.");

        // swap WBTC to WETH
        swap_weth(amount_owed, wbtc_bal);

        // calculate amount owed in WETH, since we are using WETH/USDT flash swap
        // uint256 weth_amount_owed = get_swap_in(amount_owed, WETH, USDT, false);
        // console.log(weth_amount_owed);

        // 2.3 repay
        //    *** Your code here ***
        // repay the flash loan
        IERC20(USDT).safeTransfer(msg.sender, amount_owed);
        // IERC20(WETH).safeTransfer(msg.sender, weth_amount_owed);
        
        // END TODO
    }
}
