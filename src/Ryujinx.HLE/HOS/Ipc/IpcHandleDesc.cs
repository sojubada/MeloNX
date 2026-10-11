using Ryujinx.Common.Memory;
using System;
using System.Buffers.Binary;

namespace Ryujinx.HLE.HOS.Ipc
{
    class IpcHandleDesc
    {
        public bool HasPId { get; private set; }

        public ulong PId { get; private set; }

        public int[] ToCopy { get; private set; }
        public int[] ToMove { get; private set; }

        /// <summary>
        /// Size of this descriptor when serialized, in bytes.
        /// </summary>
        public int SizeInBytes =>
            sizeof(int) +
            (HasPId ? sizeof(ulong) : 0) +
            (ToCopy.Length + ToMove.Length) * sizeof(int);

        private IpcHandleDesc()
        {
        }

        public IpcHandleDesc(int[] copy, int[] move)
        {
            ToCopy = copy ?? throw new ArgumentNullException(nameof(copy));
            ToMove = move ?? throw new ArgumentNullException(nameof(move));
        }

        public IpcHandleDesc(int[] copy, int[] move, ulong pId) : this(copy, move)
        {
            PId = pId;

            HasPId = true;
        }

        public static IpcHandleDesc MakeCopy(params int[] handles)
        {
            return new IpcHandleDesc(handles, []);
        }

        public static IpcHandleDesc MakeMove(params int[] handles)
        {
            return new IpcHandleDesc([], handles);
        }

        /// <summary>
        /// Parses a handle descriptor at <paramref name="offset"/>, advancing it past the descriptor.
        /// </summary>
        public static IpcHandleDesc Parse(ReadOnlySpan<byte> data, ref int offset)
        {
            IpcHandleDesc desc = new();

            int word = BinaryPrimitives.ReadInt32LittleEndian(data[offset..]);

            offset += sizeof(int);

            desc.HasPId = (word & 1) != 0;

            if (desc.HasPId)
            {
                desc.PId = BinaryPrimitives.ReadUInt64LittleEndian(data[offset..]);

                offset += sizeof(ulong);
            }

            desc.ToCopy = ReadHandles(data, ref offset, (word >> 1) & 0xf);
            desc.ToMove = ReadHandles(data, ref offset, (word >> 5) & 0xf);

            return desc;
        }

        private static int[] ReadHandles(ReadOnlySpan<byte> data, ref int offset, int count)
        {
            if (count == 0)
            {
                return [];
            }

            int[] handles = new int[count];

            for (int index = 0; index < count; index++)
            {
                handles[index] = BinaryPrimitives.ReadInt32LittleEndian(data[offset..]);

                offset += sizeof(int);
            }

            return handles;
        }

        /// <summary>
        /// Serializes this descriptor, advancing <paramref name="writer"/> past it.
        /// </summary>
        public void Write(ref SpanWriter writer)
        {
            int word = HasPId ? 1 : 0;

            word |= (ToCopy.Length & 0xf) << 1;
            word |= (ToMove.Length & 0xf) << 5;

            writer.Write(word);

            if (HasPId)
            {
                writer.Write(PId);
            }

            foreach (int handle in ToCopy)
            {
                writer.Write(handle);
            }

            foreach (int handle in ToMove)
            {
                writer.Write(handle);
            }
        }
    }
}
