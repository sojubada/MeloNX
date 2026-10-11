using Ryujinx.Common.Memory;
using System;
using System.Buffers;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;

namespace Ryujinx.HLE.HOS.Ipc
{
    class IpcMessage : IDisposable
    {
        public IpcMessageType Type { get; set; }

        public IpcHandleDesc HandleDesc { get; set; }

        public List<IpcPtrBuffDesc> PtrBuff { get; }
        public List<IpcBuffDesc> SendBuff { get; }
        public List<IpcBuffDesc> ReceiveBuff { get; }
        public List<IpcBuffDesc> ExchangeBuff { get; }
        public List<IpcRecvListBuffDesc> RecvListBuff { get; }

        public List<int> ObjectIds { get; }

        private byte[] _rawData = [];
        private int _rawDataLength;

        private byte[] _messageBuffer = [];

        /// <summary>
        /// Raw data of the message, excluding all headers and descriptors.
        /// </summary>
        public ReadOnlySpan<byte> RawData => _rawData.AsSpan(0, _rawDataLength);

        /// <summary>
        /// Length of <see cref="RawData"/>, in bytes.
        /// </summary>
        public int RawDataLength => _rawDataLength;

        public IpcMessage()
        {
            PtrBuff = [];
            SendBuff = [];
            ReceiveBuff = [];
            ExchangeBuff = [];
            RecvListBuff = [];

            ObjectIds = [];
        }

        /// <summary>
        /// Clears the message, so that it can be reused for another request or response.
        /// </summary>
        public void Reset()
        {
            Type = default;
            HandleDesc = null;

            PtrBuff.Clear();
            SendBuff.Clear();
            ReceiveBuff.Clear();
            ExchangeBuff.Clear();
            RecvListBuff.Clear();

            ObjectIds.Clear();

            _rawDataLength = 0;
        }

        /// <summary>
        /// Reserves <paramref name="length"/> bytes of raw data and returns them for writing.
        /// The contents are undefined, the caller is expected to overwrite them fully.
        /// </summary>
        public Span<byte> AllocRawData(int length)
        {
            if (_rawData.Length < length)
            {
                ReturnBuffer(ref _rawData);

                _rawData = ArrayPool<byte>.Shared.Rent(length);
            }

            _rawDataLength = length;

            return _rawData.AsSpan(0, length);
        }

        public void SetRawData(ReadOnlySpan<byte> data)
        {
            data.CopyTo(AllocRawData(data.Length));
        }

        /// <summary>
        /// Parses a message from the guest TLS area, replacing any state this instance had.
        /// </summary>
        /// <param name="data">Message data, as read from the guest</param>
        /// <param name="cmdPtr">Guest address <paramref name="data"/> was read from, used for padding calculations</param>
        public void Parse(ReadOnlySpan<byte> data, long cmdPtr)
        {
            Reset();

            int word0 = BinaryPrimitives.ReadInt32LittleEndian(data);
            int word1 = BinaryPrimitives.ReadInt32LittleEndian(data[sizeof(int)..]);

            int offset = sizeof(int) * 2;

            Type = (IpcMessageType)(word0 & 0xffff);

            int ptrBuffCount = (word0 >> 16) & 0xf;
            int sendBuffCount = (word0 >> 20) & 0xf;
            int recvBuffCount = (word0 >> 24) & 0xf;
            int xchgBuffCount = (word0 >> 28) & 0xf;

            int rawDataSize = (word1 >> 0) & 0x3ff;
            int recvListFlags = (word1 >> 10) & 0xf;
            bool hndDescEnable = ((word1 >> 31) & 0x1) != 0;

            if (hndDescEnable)
            {
                HandleDesc = IpcHandleDesc.Parse(data, ref offset);
            }

            PtrBuff.EnsureCapacity(ptrBuffCount);

            for (int index = 0; index < ptrBuffCount; index++)
            {
                PtrBuff.Add(new IpcPtrBuffDesc(data[offset..]));

                offset += IpcPtrBuffDesc.SizeInBytes;
            }

            ReadBuff(SendBuff, sendBuffCount, data, ref offset);
            ReadBuff(ReceiveBuff, recvBuffCount, data, ref offset);
            ReadBuff(ExchangeBuff, xchgBuffCount, data, ref offset);

            rawDataSize *= sizeof(int);

            int recvListPos = offset + rawDataSize;

            // Only CMIF has the padding requirements.
            if (Type < IpcMessageType.TipcCloseSession)
            {
                int pad0 = (int)GetPadSize16(offset + cmdPtr);

                if (rawDataSize != 0)
                {
                    rawDataSize -= pad0;
                }

                offset += pad0;
            }

            int recvListCount = recvListFlags - 2;

            if (recvListCount == 0)
            {
                recvListCount = 1;
            }
            else if (recvListCount < 0)
            {
                recvListCount = 0;
            }

            // The raw data size is attacker (guest) controlled and can be larger than the message
            // area that was read, so clamp it rather than faulting on a malformed message.
            rawDataSize = Math.Clamp(rawDataSize, 0, data.Length - offset);

            SetRawData(data.Slice(offset, rawDataSize));

            offset = recvListPos;

            RecvListBuff.EnsureCapacity(recvListCount);

            for (int index = 0; index < recvListCount; index++)
            {
                RecvListBuff.Add(new IpcRecvListBuffDesc(BinaryPrimitives.ReadUInt64LittleEndian(data[offset..])));

                offset += sizeof(ulong);
            }
        }

        private static void ReadBuff(List<IpcBuffDesc> buff, int count, ReadOnlySpan<byte> data, ref int offset)
        {
            buff.EnsureCapacity(count);

            for (int index = 0; index < count; index++)
            {
                buff.Add(new IpcBuffDesc(data[offset..]));

                offset += IpcBuffDesc.SizeInBytes;
            }
        }

        /// <summary>
        /// Serializes the message as a CMIF response. The returned span is only valid until the next
        /// call to <see cref="GetResponse"/> or <see cref="GetResponseTipc"/> on this instance.
        /// </summary>
        public ReadOnlySpan<byte> GetResponse(long cmdPtr, ulong recvListAddr)
        {
            int handleLength = HandleDesc?.SizeInBytes ?? 0;
            int ptrBuffLength = PtrBuff.Count * IpcPtrBuffDesc.SizeInBytes;

            int rawLength = (_rawDataLength + 3) & ~3;

            int pad0 = (int)GetPadSize16(cmdPtr + sizeof(int) * 2 + handleLength + ptrBuffLength);

            // Apparently, padding after Raw Data is 16 bytes, however when there is
            // padding before Raw Data too, we need to subtract the size of this padding.
            // This is the weirdest padding I've seen so far...
            int pad1 = 0x10 - pad0;

            int dataLength = (rawLength + pad0 + pad1) / sizeof(int);

            int word0 = (int)Type;
            word0 |= (PtrBuff.Count & 0xf) << 16;
            word0 |= (SendBuff.Count & 0xf) << 20;
            word0 |= (ReceiveBuff.Count & 0xf) << 24;
            word0 |= (ExchangeBuff.Count & 0xf) << 28;

            int word1 = (dataLength & 0x3ff) | (2 << 10);

            if (HandleDesc != null)
            {
                word1 |= 1 << 31;
            }

            int size = sizeof(int) * 2 + handleLength + ptrBuffLength + pad0 + rawLength + pad1 + sizeof(ulong);

            SpanWriter writer = new(EnsureMessageBuffer(size));

            writer.Write(word0);
            writer.Write(word1);

            HandleDesc?.Write(ref writer);

            foreach (IpcPtrBuffDesc ptrBuffDesc in PtrBuff)
            {
                writer.Write(ptrBuffDesc.GetWord0());
                writer.Write(ptrBuffDesc.GetWord1());
            }

            // The buffer is zeroed by EnsureMessageBuffer, so all padding can just be skipped over.
            writer.Skip(pad0);

            writer.Write(RawData);
            writer.Skip(rawLength - _rawDataLength);

            writer.Skip(pad1);

            writer.Write(recvListAddr);

            return _messageBuffer.AsSpan(0, size);
        }

        /// <summary>
        /// Serializes the message as a TIPC response. The returned span is only valid until the next
        /// call to <see cref="GetResponse"/> or <see cref="GetResponseTipc"/> on this instance.
        /// </summary>
        public ReadOnlySpan<byte> GetResponseTipc()
        {
            Debug.Assert(PtrBuff.Count == 0);

            int handleLength = HandleDesc?.SizeInBytes ?? 0;

            int dataLength = ((_rawDataLength + 3) & ~3) / sizeof(int);

            int word0 = (int)Type;
            word0 |= (SendBuff.Count & 0xf) << 20;
            word0 |= (ReceiveBuff.Count & 0xf) << 24;
            word0 |= (ExchangeBuff.Count & 0xf) << 28;

            int word1 = dataLength & 0x3ff;

            if (HandleDesc != null)
            {
                word1 |= 1 << 31;
            }

            int size = sizeof(int) * 2 + handleLength + _rawDataLength;

            SpanWriter writer = new(EnsureMessageBuffer(size));

            writer.Write(word0);
            writer.Write(word1);

            HandleDesc?.Write(ref writer);

            writer.Write(RawData);

            return _messageBuffer.AsSpan(0, size);
        }

        private Span<byte> EnsureMessageBuffer(int size)
        {
            if (_messageBuffer.Length < size)
            {
                ReturnBuffer(ref _messageBuffer);

                _messageBuffer = ArrayPool<byte>.Shared.Rent(size);
            }

            Span<byte> buffer = _messageBuffer.AsSpan(0, size);

            buffer.Clear();

            return buffer;
        }

        private static void ReturnBuffer(ref byte[] buffer)
        {
            if (buffer.Length != 0)
            {
                ArrayPool<byte>.Shared.Return(buffer);

                buffer = [];
            }
        }

        private static long GetPadSize16(long position)
        {
            if ((position & 0xf) != 0)
            {
                return 0x10 - (position & 0xf);
            }

            return 0;
        }

        // ReSharper disable once InconsistentNaming
        public (ulong Position, ulong Size) GetBufferType0x21(int index = 0)
        {
            if (PtrBuff.Count > index && PtrBuff[index].Position != 0)
            {
                return (PtrBuff[index].Position, PtrBuff[index].Size);
            }

            if (SendBuff.Count > index)
            {
                return (SendBuff[index].Position, SendBuff[index].Size);
            }

            return (0, 0);
        }

        // ReSharper disable once InconsistentNaming
        public (ulong Position, ulong Size) GetBufferType0x22(int index = 0)
        {
            if (RecvListBuff.Count > index && RecvListBuff[index].Position != 0)
            {
                return (RecvListBuff[index].Position, RecvListBuff[index].Size);
            }

            if (ReceiveBuff.Count > index)
            {
                return (ReceiveBuff[index].Position, ReceiveBuff[index].Size);
            }

            return (0, 0);
        }

        public void Dispose()
        {
            ReturnBuffer(ref _rawData);
            ReturnBuffer(ref _messageBuffer);

            _rawDataLength = 0;
        }
    }
}
