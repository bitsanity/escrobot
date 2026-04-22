# ESCROBOT

escrobot is a smart contract that implements the back end of an automated escrow service.

It works as follows:
* A buyer and seller want to make a transaction with escrow support
* The seller submits an Order via this contract
* The buyer submits payment plus a bond that will be returned when they confirm receipt of the item.
* The seller fulfils the request and ships, then updates this contract with the tracking reference.
* The buyer receives the item and confirms so with this contract.
* The contract pays the seller and returns the buyer's bond.

## Admin

Decentralization is the ultimate goal but someone/something still has to act as an admin.

The admin can:
* reassign admin to another address
* **force resolution** of deals that get stuck and so need arbitration

A deal could otherwise get stuck if:
* a seller lies about shipping
* a client lies and says they have not received the item
* the item is lost or destroyed in transit

The admin **cannot**:
* prevent any accounts from using this contract
* take funds from this contract
* alter or impede escrow deals in progress within this contract
