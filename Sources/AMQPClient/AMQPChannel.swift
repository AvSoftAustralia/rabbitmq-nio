//===----------------------------------------------------------------------===//
//
// This source file is part of the RabbitMQNIO project
//
// Copyright (c) 2022 Krzysztof Majk
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOConcurrencyHelpers
import Atomics
import AMQPProtocol

public final class AMQPChannel {
    public let channelID: Frame.ChannelID
    private var eventLoopGroup: EventLoopGroup

    private var lock = NIOLock()
    private var _connection: AMQPConnection?
    private var connection: AMQPConnection? {
        get {
            self.lock.withLock {
                _connection
            }
        }
        set {
            self.lock.withLock {
                _connection = newValue
            }
        }
    }

    private var _notifier: Notifiable?
    private var notifier: Notifiable? {
        get {
            self.lock.withLock {
                _notifier
            }
        }
        set {
            self.lock.withLock {
                _notifier = newValue
            }
        }
    }

    private var closeListeners = AMQPListeners<Void>()

    private let isConfirmMode = ManagedAtomic(false)
    private let isTxMode = ManagedAtomic(false)
    private let prefetchCount = ManagedAtomic(UInt16(0))
    private let deliveryTag = ManagedAtomic(UInt64(1))

    init(channelID: Frame.ChannelID, eventLoopGroup: EventLoopGroup, notifier: Notifiable, connection: AMQPConnection) {
        self.channelID = channelID
        self.eventLoopGroup = eventLoopGroup
        self.notifier = notifier
        self.connection = connection

        connection.closeFuture.whenComplete { result in
            self.connection = nil
            
            self.notifier = nil
            self.closeListeners.notify(result)
        }

        notifier.closeFuture.whenComplete { result in
            self.notifier = nil
            self.closeListeners.notify(result)
        }
    }

    public func close(reason: String = "", code: UInt16 = 200) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .channel(.close(.init(replyCode: code, replyText: reason, classID: 0, methodID: 0)))), immediate: true)
        .flatMapThrowing { response in
            guard case .channel(let channel) = response, case .closed = channel else {
                throw ClientError.invalidResponse(response)
            }

            self.notifier = nil

            self.closeListeners.notify(.success(()))

            return response
        }
    }

    public func basicGet(queue: String, noAck: Bool = true) -> EventLoopFuture<AMQPMessage.Get?> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .basic(.get(.init(reserved1: 0, queue: queue, noAck: noAck)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .message(let message) = channel, case .get(let get) = message else {
                    throw ClientError.invalidResponse(response)
                }
                return get
            }
    }


    public func basicPublish(body: ByteBuffer, exchange: String, routingKey: String, mandatory: Bool = false,  immediate: Bool = false, properties: Properties = Properties()) -> EventLoopFuture<Void> {
        guard let body = body.getBytes(at: 0, length: body.readableBytes) else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.invalidBody) }

        return self.basicPublish(body: body, exchange: exchange, routingKey: routingKey, mandatory: mandatory,  immediate: immediate, properties: properties)
    }

    public func basicPublish(body: [UInt8], exchange: String, routingKey: String, mandatory: Bool = false,  immediate: Bool = false, properties: Properties = Properties()) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        let publish = Frame.method(self.channelID, .basic(.publish(.init(reserved1: 0, exchange: exchange, routingKey: routingKey, mandatory: mandatory, immediate: immediate))))
        let header = Frame.header(self.channelID, .init(classID: 60, weight: 0, bodySize: UInt64(body.count), properties: properties))
        let body = Frame.body(self.channelID, body: body)

        return connection.sendFrames(frames: [publish, header, body], immediate: true)
    }

    public func basicPublishConfirm(body: ByteBuffer, exchange: String, routingKey: String, mandatory: Bool = false,  immediate: Bool = false, properties: Properties = Properties()) -> EventLoopFuture<UInt64> {
        guard let body = body.getBytes(at: 0, length: body.readableBytes) else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.invalidBody) }

        return self.basicPublishConfirm(body: body, exchange: exchange, routingKey: routingKey, mandatory: mandatory,  immediate: immediate, properties: properties)
    }

    public func basicPublishConfirm(body: [UInt8], exchange: String, routingKey: String, mandatory: Bool = false,  immediate: Bool = false, properties: Properties = Properties()) -> EventLoopFuture<UInt64> {
        guard self.isConfirmMode.load(ordering: .relaxed) else { return self.eventLoopGroup.next().makeFailedFuture( ClientError.channelNotInConfirmMode) }
        
        let response: EventLoopFuture<Void> = self.basicPublish(body: body, exchange: exchange, routingKey: routingKey, mandatory: mandatory,  immediate: immediate, properties: properties)
        return response
            .flatMap { _ in
                let count = self.deliveryTag.loadThenWrappingIncrement(ordering: .acquiring)
                return self.eventLoopGroup.next().makeSucceededFuture(count)
            }       
    }

    public func queueDeclare(name: String, passive: Bool = false, durable: Bool = false, exclusive: Bool = false, autoDelete: Bool = false, args arguments: Table =  Table()) -> EventLoopFuture<AMQPResponse>  {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .queue(.declare(.init(reserved1: 0, queueName: name, passive: passive, durable: durable, exclusive: exclusive, autoDelete: autoDelete, noWait: false, arguments: arguments)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .queue(let queue) = channel, case .declared = queue else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    public func queueDelete(name: String, ifUnused: Bool = false, ifEmpty: Bool = false) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .queue(.delete(.init(reserved1: 0, queueName: name, ifUnused: ifUnused, ifEmpty: ifEmpty, noWait: false)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .queue(let queue) = channel, case .deleted = queue else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    public func queuePurge(name: String) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .queue(.purge(.init(reserved1: 0, queueName: name, noWait: false)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .queue(let queue) = channel, case .purged = queue else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    public func queueBind(queue: String, exchange: String, routingKey: String, args arguments: Table = Table()) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .queue(.bind(.init(reserved1: 0, queueName: queue, exchangeName: exchange, routingKey: routingKey, noWait: false, arguments: arguments)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .queue(let queue) = channel, case .binded = queue else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    public func queueUnbind(queue: String, exchange: String, routingKey: String, args arguments: Table = Table()) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .queue(.unbind(.init(reserved1: 0, queueName: queue, exchangeName: exchange, routingKey: routingKey, arguments: arguments)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .queue(let queue) = channel, case .unbinded = queue else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    public func exchangeDeclare(name: String, type: String, passive: Bool = false, durable: Bool = true, autoDelete: Bool = false,  internal: Bool = false, args arguments: Table = Table()) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .exchange(.declare(.init(reserved1: 0, exchangeName: name, exchangeType: type, passive: passive, durable: durable, autoDelete: autoDelete, internal: `internal`, noWait: false, arguments: arguments)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .exchange(let exchange) = channel, case .declared = exchange else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    public func exchangeDelete(name: String, ifUnused: Bool = false) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .exchange(.delete(.init(reserved1: 0, exchangeName: name, ifUnused: ifUnused, noWait: false)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .exchange(let exchange) = channel, case .deleted = exchange else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    public func exchangeBind(destination: String, source: String, routingKey: String, args arguments: Table = Table()) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .exchange(.bind(.init(reserved1: 0, destination: destination, source: source, routingKey: routingKey, noWait: false, arguments: arguments)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .exchange(let exchange) = channel, case .binded = exchange else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    public func exchangeUnbind(destination: String, source: String, routingKey: String, args arguments: Table = Table()) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .exchange(.unbind(.init(reserved1: 0, destination: destination, source: source, routingKey: routingKey, noWait: false, arguments: arguments)))), immediate: true)
            .flatMapThrowing { response in 
                guard case .channel(let channel) = response, case .exchange(let exchange) = channel, case .unbinded = exchange else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    /// Tell the broker to either deliver all unacknowledge messages again if *requeue* is false or rejecting all if *requeue* is true
    ///
    /// Unacknowledged messages retrived by `basic_get` are requeued regardless.
    public func basicRecover(requeue: Bool) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .basic(.recover(requeue: requeue))), immediate: true)
            .flatMapThrowing { response in
                guard case .channel(let channel) = response, case .basic(let basic) = channel, case .recovered = basic else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    /// Sets the channel in publish confirm mode, each published message will be acked or nacked
    public func confirmSelect() -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        guard !self.isConfirmMode.load(ordering: .relaxed) else {
            return self.eventLoopGroup.any().makeSucceededFuture(.channel(.confirm(.alreadySelected)))
        }

        return connection.sendFrame(frame: .method(self.channelID, .confirm(.select(noWait: false))), immediate: true)
            .flatMapThrowing { response in
                guard case .channel(let channel) = response, case .confirm(let confirm) = channel, case .selected = confirm else {
                    throw ClientError.invalidResponse(response)
                }

                self.isConfirmMode.store(true, ordering: .relaxed)

                return response
            }
    }

    /// Set the Channel in transaction mode
    public func txSelect() -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        guard !self.isTxMode.load(ordering: .relaxed) else {
            return self.eventLoopGroup.any().makeSucceededFuture(.channel(.tx(.alreadySelected)))
        }

        return connection.sendFrame(frame: .method(self.channelID, .tx(.select)), immediate: true)
            .flatMapThrowing { response in
                guard case .channel(let channel) = response, case .tx(let tx) = channel, case .selected = tx else {
                    throw ClientError.invalidResponse(response)
                }

                self.isTxMode.store(true, ordering: .relaxed)

                return response
            }
    }

    /// Commit a transaction
    public func txCommit() -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .tx(.commit)), immediate: true)
            .flatMapThrowing { response in
                guard case .channel(let channel) = response, case .tx(let tx) = channel, case .committed = tx else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    /// Rollback a transaction
    public func txRollback() -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .tx(.rollback)), immediate: true)
            .flatMapThrowing { response in
                guard case .channel(let channel) = response, case .tx(let tx) = channel, case .rollbacked = tx else {
                    throw ClientError.invalidResponse(response)
                }
                return response
            }
    }

    /// Set prefetch limit to *count* messages,
    /// no more messages will be delivered to the consumer until one or more message have been acknowledged or rejected
    public func basicQos(count: UInt16, global: Bool = false) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .basic(.qos(prefetchSize: 0, prefetchCount: count, global: global))), immediate: true)
            .flatMapThrowing { response in
                guard case .channel(let channel) = response, case .basic(let basic) = channel, case .qosed = basic else {
                    throw ClientError.invalidResponse(response)
                }

                self.prefetchCount.store(count, ordering: .relaxed)

                return response
            }
    }

    public func basicAck(deliveryTag: UInt64, multiple: Bool = false) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .basic(.ack(deliveryTag: deliveryTag, multiple: multiple))), immediate: true)
    }

    public func basicAck(message: AMQPMessage.Delivery,  multiple: Bool = false) -> EventLoopFuture<Void> {
        return self.basicAck(deliveryTag: message.deliveryTag, multiple: multiple)
    }

    public func basicNack(deliveryTag: UInt64, multiple: Bool = false, requeue: Bool = false) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .basic(.nack(.init(deliveryTag: deliveryTag, multiple: multiple, requeue: requeue)))), immediate: true)
    }

    public func basicNack(message: AMQPMessage.Delivery, multiple: Bool = false, requeue: Bool = false) -> EventLoopFuture<Void> {
        return self.basicNack(deliveryTag: message.deliveryTag, multiple: multiple, requeue: requeue)
    }

    public func basicReject(deliveryTag: UInt64, requeue: Bool = false) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .basic(.reject(deliveryTag: deliveryTag, requeue: requeue))), immediate: true)
    }

    public func basicReject(message: AMQPMessage.Delivery, requeue: Bool = false) -> EventLoopFuture<Void> {
        return self.basicReject(deliveryTag: message.deliveryTag, requeue: requeue)
    }

    /// Stop/start the flow of messages to consumers
    /// Not supported by all brokers
    public func flow(active: Bool) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .channel(.flow(active: active))), immediate: true)
            .flatMapThrowing { response in
                guard case .channel(let channel) = response, case .flowed = channel else {
                    throw ClientError.invalidResponse(response)
                }

                return response
            }
    }

    func basicConsume(queue: String, consumerTag: String = "", noAck: Bool = false, exclusive: Bool = false, args arguments: Table = Table()) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .basic(.consume(.init(reserved1: 0, queue: queue, consumerTag: consumerTag, noLocal: false, noAck: noAck, exclusive: exclusive, noWait: false, arguments: arguments)))), immediate: true)
    }

    public func basicConsume(queue: String, consumerTag: String = "", noAck: Bool = false, exclusive: Bool = false, args arguments: Table = Table(), listener: @escaping (Result<AMQPMessage.Delivery, Error>) -> Void) -> EventLoopFuture<AMQPResponse> { 
        return self.basicConsume(queue: queue, consumerTag: consumerTag, noAck: noAck, exclusive: exclusive, args: arguments)
            .flatMapThrowing { response in
                guard case .channel(let channel) = response, case .basic(let basic) = channel, case .consumed(let tag) = basic else {
                    throw ClientError.invalidResponse(response)
                }

                try self.addConsumeListener(consumerTag: tag, listener: listener)
                return response
            }
    }

    public func cancel(consumerTag: String) -> EventLoopFuture<AMQPResponse> {
        guard let connection = self.connection else { return self.eventLoopGroup.next().makeFailedFuture(ClientError.connectionClosed()) }

        return connection.sendFrame(frame: .method(self.channelID, .basic(.cancel(.init(consumerTag: consumerTag, noWait: false)))), immediate: true)
            .flatMapThrowing { response in
                guard case .channel(let channel) = response, case .basic(let basic) = channel, case .canceled = basic else {
                    throw ClientError.invalidResponse(response)
                }

                return response
            }
    }

    public func addConsumeListener(consumerTag: String, listener: @escaping (Result<AMQPMessage.Delivery, Error>) -> Void) throws {
        guard let notifier = self.notifier else { throw ClientError.channelClosed() }

        return notifier.addConsumeListener(named: consumerTag, listener: listener)   
    }

    public func removeConsumeListener(consumerTag: String) {
        guard let notifier = self.notifier else { return }

        return notifier.removeConsumeListener(named: consumerTag)   
    }

    public func addCloseListener(named name: String, listener: @escaping (Result<Void, Error>) -> Void)  {
        return self.closeListeners.addListener(named: name, listener: listener)
    }

    public func removeCloseListener(named name: String)  {
        return self.closeListeners.removeListener(named: name)
    }

    public func addFlowListener(named name: String,  listener: @escaping (Result<Bool, Error>) -> Void) throws {
        guard let notifier = self.notifier else { throw ClientError.channelClosed() }

        return notifier.addFlowListener(named: name, listener: listener)
    }

    public func removeFlowListener(named name: String)  {
        guard let notifier = self.notifier else { return }

        return notifier.removeFlowListener(named: name)   
    }

    public func addReturnListener(named name: String,  listener: @escaping (Result<AMQPMessage.Return, Error>) -> Void) throws {
        guard let notifier = self.notifier else { throw ClientError.channelClosed() }

        return notifier.addReturnListener(named: name, listener: listener)
    }

    public func removeReturnFlowListener(named name: String)  {
        guard let notifier = self.notifier else { return }

        return notifier.removeReturnListener(named: name)   
    }

    public func addPublishListener(named name: String,  listener: @escaping (Result<AMQPResponse.Channel.Basic.PublishConfirm, Error>) -> Void) throws {
        guard let notifier = self.notifier else { throw ClientError.channelClosed() }

        guard self.isConfirmMode.load(ordering: .relaxed) else {
            throw ClientError.channelNotInConfirmMode
        }

        return notifier.addPublishListener(named: name, listener: listener)
    }

    public func removePublishListener(named name: String)  {
        guard let notifier = self.notifier else { return }

        return notifier.removePublishListener(named: name)
    }
}
