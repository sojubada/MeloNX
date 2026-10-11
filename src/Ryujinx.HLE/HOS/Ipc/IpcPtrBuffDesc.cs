using System;
using System.Buffers.Binary;

namespace Ryujinx.HLE.HOS.Ipc
{
    struct IpcPtrBuffDesc
    {
        public const int SizeInBytes = sizeof(uint) * 2;

        public ulong Position { get; private set; }
        public uint Index { get; private set; }
        public ulong Size { get; private set; }

        public IpcPtrBuffDesc(ulong position, uint index, ulong size)
        {
            Position = position;
            Index = index;
            Size = size;
        }

        public IpcPtrBuffDesc(ReadOnlySpan<byte> data)
        {
            ulong word0 = BinaryPrimitives.ReadUInt32LittleEndian(data);
            ulong word1 = BinaryPrimitives.ReadUInt32LittleEndian(data[sizeof(uint)..]);

            Position = word1;
            Position |= (word0 << 20) & 0x0f00000000;
            Position |= (word0 << 30) & 0x7000000000;

            Index = ((uint)word0 >> 0) & 0x03f;
            Index |= ((uint)word0 >> 3) & 0x1c0;

            Size = (ushort)(word0 >> 16);
        }

        public readonly IpcPtrBuffDesc WithSize(ulong size)
        {
            return new IpcPtrBuffDesc(Position, Index, size);
        }

        public readonly uint GetWord0()
        {
            uint word0;

            word0 = (uint)((Position & 0x0f00000000) >> 20);
            word0 |= (uint)((Position & 0x7000000000) >> 30);

            word0 |= (Index & 0x03f) << 0;
            word0 |= (Index & 0x1c0) << 3;

            word0 |= (uint)Size << 16;

            return word0;
        }

        public readonly uint GetWord1()
        {
            return (uint)Position;
        }
    }
}
