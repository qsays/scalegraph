#ifndef __ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__SINGLEFILENAMEPROVIDER__SINGLEPATHITERATOR_H
#define __ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__SINGLEFILENAMEPROVIDER__SINGLEPATHITERATOR_H

#include <x10rt.h>


#define ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__PATHITERATOR_H_NODEPS
#include <org/scalegraph/io/impl/FileNameProvider__PathIterator.h>
#undef ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__PATHITERATOR_H_NODEPS
namespace org { namespace scalegraph { namespace io { namespace impl { 
class FileNameProvider;
} } } } 
namespace x10 { namespace lang { 
class Boolean;
} } 
namespace org { namespace scalegraph { namespace io { namespace impl { 

class FileNameProvider__SingleFileNameProvider__SinglePathIterator : public org::scalegraph::io::impl::FileNameProvider__PathIterator
  {
    public:
    RTT_H_DECLS_CLASS
    
    static x10aux::itable_entry _itables[3];
    
    virtual x10aux::itable_entry* _getITables() { return _itables; }
    
    static x10::lang::Iterator<org::scalegraph::util::SString>::itable<org::scalegraph::io::impl::FileNameProvider__SingleFileNameProvider__SinglePathIterator > _itable_0;
    
    static x10::lang::Any::itable<org::scalegraph::io::impl::FileNameProvider__SingleFileNameProvider__SinglePathIterator > _itable_1;
    
    void _constructor(org::scalegraph::io::impl::FileNameProvider* th);
    
    static org::scalegraph::io::impl::FileNameProvider__SingleFileNameProvider__SinglePathIterator* _make(
             org::scalegraph::io::impl::FileNameProvider* th);
    
    virtual x10_boolean hasNext();
    virtual org::scalegraph::io::impl::FileNameProvider__SingleFileNameProvider__SinglePathIterator*
      org__scalegraph__io__impl__FileNameProvider__SingleFileNameProvider__SinglePathIterator____this__org__scalegraph__io__impl__FileNameProvider__SingleFileNameProvider__SinglePathIterator(
      );
    
    // Serialization
    public: static const x10aux::serialization_id_t _serialization_id;
    
    public: virtual x10aux::serialization_id_t _get_serialization_id() {
         return _serialization_id;
    }
    
    public: virtual void _serialize_body(x10aux::serialization_buffer& buf);
    
    public: static x10::lang::Reference* _deserializer(x10aux::deserialization_buffer& buf);
    
    public: void _deserialize_body(x10aux::deserialization_buffer& buf);
    
};


} } } } 
#endif // ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__SINGLEFILENAMEPROVIDER__SINGLEPATHITERATOR_H

namespace org { namespace scalegraph { namespace io { namespace impl { 
class FileNameProvider__SingleFileNameProvider__SinglePathIterator;
} } } } 

#ifndef ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__SINGLEFILENAMEPROVIDER__SINGLEPATHITERATOR_H_NODEPS
#define ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__SINGLEFILENAMEPROVIDER__SINGLEPATHITERATOR_H_NODEPS
#ifndef ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__SINGLEFILENAMEPROVIDER__SINGLEPATHITERATOR_H_GENERICS
#define ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__SINGLEFILENAMEPROVIDER__SINGLEPATHITERATOR_H_GENERICS
#endif // ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__SINGLEFILENAMEPROVIDER__SINGLEPATHITERATOR_H_GENERICS
#endif // __ORG_SCALEGRAPH_IO_IMPL_FILENAMEPROVIDER__SINGLEFILENAMEPROVIDER__SINGLEPATHITERATOR_H_NODEPS
