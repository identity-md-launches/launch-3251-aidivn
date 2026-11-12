// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ADVNToken} from "../../src/ADVNToken.sol";

/// @notice Stands in for the launch factory in unit tests: deploys the token (so the supply is minted
///         to it), answers `distributorOf` like the real factory, and forwards tokens on request.
contract MockFactory {
    mapping(uint64 => address) public distributorOf;

    function deployToken(address poolManager, uint64 launchNumber) external returns (ADVNToken) {
        return new ADVNToken(address(this), poolManager, launchNumber);
    }

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function move(ADVNToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice A factory whose `distributorOf` reverts: the token must still transfer (taxed) when the
///         lookup fails.
contract RevertingFactory {
    function deployToken(address poolManager, uint64 launchNumber) external returns (ADVNToken) {
        return new ADVNToken(address(this), poolManager, launchNumber);
    }

    function distributorOf(uint64) external pure returns (address) {
        revert("no distributor");
    }

    function move(ADVNToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice A factory whose `distributorOf` returns something that is not a 32-byte word.
contract ShortAnswerFactory {
    function deployToken(address poolManager, uint64 launchNumber) external returns (ADVNToken) {
        return new ADVNToken(address(this), poolManager, launchNumber);
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 8)
        }
    }

    function move(ADVNToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}
