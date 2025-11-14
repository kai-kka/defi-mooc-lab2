### Get the API url from Alchemy (Required)
1. Sign in an Alchemy account.
2. Create an app.
3. Copy Endpoint URL on the app's dashboard.
4. Create an ```.env``` file and store the API url as ```ALCHE_API```.

### Run with Docker 
Build Docker image:
```bash
docker build -t flash_loan_liquidation .
```
Run Docker image interactively:
```bash
docker run -it --rm flash_loan_liquidation bash
```
Compile and run the test in the docker container:
```bash
npx hardhat compile
npx hardhat test
```


Flash Loan 2919549181195 USDC from circle
Exchange 2919549181195 USDC -> 2916358033172 USDT
Liquidator sends 2916378221684 (USDT)
Liquidate 9427338222 (WBTC)
flash loan return 8905424008 (WBTC) -> swap to 1477402720015790673349 (WETH) -> 2919549181195 swap to USDC



In summary, the error arises because Hardhat v2.6.1 is too old to handle modern Ethereum node responses missing the totalDifficulty field. Upgrading Hardhat to version 2.22.14 or above will automatically include a fallback for missing totalDifficulty, resolving this issue. After upgrading, your hardhat_reset forking call should work without the JSON-RPC schema error.