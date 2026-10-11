using System;
using System.Buffers.Binary;

namespace Ryujinx.HLE.HOS.Ipc
{
    struct IpcBuffDesc
    {
        public const int SizeInBytes = sizeof(uint) * 3;

        public ulong Position { get; private set; }
        public ulong Size { get; private set; }
        public byte Flags { get; private set; }

        public IpcBuffDesc(ReadOnlySpan<byte> data)
        {
            ulong word0 = BinaryPrimitives.ReadUInt32LittleEndian(data);
            ulong word1 = BinaryPrimitives.ReadUInt32LittleEndian(data[sizeof(uint)..]);
            ulong word2 = BinaryPrimitives.ReadUInt32LittleEndian(data[(sizeof(uint) * 2)..]);

            Position = word1;
            Position |= (word2 << 4) & 0x0f00000000;
            Position |= (word2 << 34) & 0x7000000000;

            Size = word0;
            Size |= (word2 << 8) & 0xf00000000;

            Flags = (byte)(word2 & 3);
        }
    }
}
