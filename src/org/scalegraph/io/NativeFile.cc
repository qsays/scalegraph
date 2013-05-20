
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include <x10aux/config.h>

#include <x10/io/FileNotFoundException.h>
#include <x10/io/IOException.h>
#include <x10/lang/IllegalArgumentException.h>

#include "org/scalegraph/io/NativeFile.h"

namespace org { namespace scalegraph { namespace io {

using namespace ::x10::lang;
using ::x10::io::FileNotFoundException;
using ::x10::io::IOException;
using ::x10::lang::IllegalArgumentException;

NativeFile NativeFile::_make(x10::lang::String* name, int  fileMode, int fileAccess) {
	NativeFile ret;
	ret._constructor(name, fileMode, fileAccess);
	return ret;
}

void NativeFile::_constructor (x10::lang::String* name, int  fileMode, int fileAccess) {
	int flags = 0;
	switch(fileAccess) {
	case 0: // Read
		flags |= O_RDONLY;
		break;
	case 1: // Write
		flags |= O_WRONLY;
		break;
	case 2: // ReadWrite
		flags |= O_RDWR;
		break;;
	default:
		x10aux::throwException(IllegalArgumentException::_make(String::Lit("FileAccess is out of range.")));
	}
	switch(fileMode) {
	case 0: // Append
		flags |= O_APPEND | O_CREAT;
		break;
	case 1: // Create
		flags |= O_CREAT | O_TRUNC;
		break;
	case 2: // CreateNew
		flags |= O_CREAT | O_EXCL;
		break;
	case 3: // Open
		flags |= 0;
		break;
	case 4: // OpenOrCreate
		flags |= O_CREAT;
		break;
	case 5: // Truncate
		flags |= O_TRUNC;
		break;
	default:
		x10aux::throwException(IllegalArgumentException::_make(String::Lit("FileMode is out of range.")));
	}
	FMGL(fd) = ::open(name->c_str(), flags, 0666);
	if (FMGL(fd) == -1)
		x10aux::throwException(FileNotFoundException::_make(name));
}

void NativeFile::close() {
	if(FMGL(fd) != -1) {
		::close(FMGL(fd));
		FMGL(fd) = -1;
	}
}

x10_long NativeFile::read(org::scalegraph::util::MemoryChunk<x10_byte> b) {
	int readBytes = ::read(FMGL(fd), b.pointer(), b.size());
	if(readBytes == -1)
		x10aux::throwException(IOException::_make(String::Lit("read error")));
	return readBytes;
}

void NativeFile::write(org::scalegraph::util::MemoryChunk<x10_byte> b) {
	int writeBytes = ::write(FMGL(fd), b.pointer(), b.size());
	if(writeBytes != b.size())
		x10aux::throwException(IOException::_make(String::Lit("write error")));
}

void NativeFile::seek(x10_long offset, int origin) {
	if(origin < 0 || origin > 2)
		x10aux::throwException(FileNotFoundException::_make());
	int map[] = {SEEK_SET, SEEK_CUR, SEEK_END};
	if(::lseek(FMGL(fd), offset, map[origin]) == -1)
		x10aux::throwException(IOException::_make(String::Lit("seek error")));
}

x10_long NativeFile::getpos() {
	x10_long pos = ::lseek(FMGL(fd), 0, SEEK_CUR);
	if(pos == -1)
		x10aux::throwException(IOException::_make(String::Lit("seek error")));
	return pos;
}

RTT_CC_DECLS0(NativeFile, "org.scalegraph.io.NativeFile", x10aux::RuntimeType::class_kind)

}}} // namespace org { namespace scalegraph { namespace io {