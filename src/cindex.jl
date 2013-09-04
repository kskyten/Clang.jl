module cindex

export parse, cu_type, cu_kind, ty_kind, name, spelling, is_function, is_null,
       value, children, cu_file, resolve_type, return_type
export CXType, CXNode, CXString, CXTypeKind, CursorList

import Base.getindex, Base.start, Base.next, Base.done, Base.search, Base.show

###############################################################################

# Name of the helper library
const libwci = :libwrapclang

###############################################################################

include("cindex/defs.jl")
include("cindex/types.jl")
include("cindex/base.jl")

###############################################################################

# Main entry point for parsing
# Returns root CXCursor in the TranslationUnit for a given header
#
# Required argument:
#   "header.h"          header file to parse
#
# Optional (keyword) arguments:
#   ClangIndex:         CXIndex pointer (pass to avoid re-allocation)
#   ClangDiagnostics:   Display Clang diagnostics
#   CPlusPlus:          Parse as C++
#   ClangArgs:       Compiler switches as string array, eg: ["-x", "c++", "-fno-elide-type"]
#   ParserOptions:      Bitwise OR of CXTranslationUnit_* flags (see docs, rarely needed)
#
function parse(header::String;
                ClangIndex                      = None,
                ClangDiagnostics::Bool          = false,
                CPlusPlus::Bool                 = false,
                ClangArgs                       = [""],
                ParserOptions                   = 0)
    if (ClangIndex == None)
        ClangIndex = idx_create(0, (ClangDiagnostics ? 0 : 1))
    end
    if (CPlusPlus)
        push!(ClangOptions, ["-x", "c++"])
    end
    
    tu = tu_parse(ClangIndex, header, ClangArgs, length(ClangArgs),
                  C_NULL, 0, ParserOptions)
    if (tu == C_NULL)
        error("ParseTranslationUnit returned NULL; unable to create TranslationUnit")
    end
    
    return tu_cursor(tu)
end


# Search function for CursorList
# Returns vector of CXCursors in CursorList matching predicate
#
# Required arguments:
#   CursorList      List to search
#   IsMatch(CXCursor)
#                   Predicate Function, accepting a CXCursor argument
#
function search(cl::CursorList, ismatch::Function)
    ret = CXNode[]
    for cu in cl
        ismatch(cu) && push!(ret, cu)
    end
    ret
end
search(cu::CXNode, ismatch::Function) = search(children(cu), ismatch)

show(io::IO, cu::CXNode) = print(io, "CXCursor: ", name(cu), " kind: ", cu_kind(cu))

###############################################################################

# TODO: macro version should be more efficient.
anymatch(first, args...) = any({==(first, a) for a in args})

cu_type(c::CXNode) = getCursorType(c)
cu_kind(c::CXNode) = getCursorKind(c)
ty_kind(c::CXType) = reinterpret(Int32, c.data[1:4])[1]
name(c::CXNode) = getCursorDisplayName(c)
spelling(c::CXType) = getTypeKindSpelling(ty_kind(c))
spelling(c::CXNode) = getCursorSpelling(c)
is_function(c::CXNode) = true # (cu_kind(c) == CurKind.FUNCTIONDECL || cu_kind(c) == 15)
is_function(t::CXType) = (ty_kind(t) == TypKind.FUNCTIONPROTO)
is_null(c::CXNode) = (Cursor_isNull(c) != 0)

function resolve_type(rt::CXType)
    # This helper attempts to work around some limitations of the
    # current libclang API.
    if ty_kind(rt) == cindex.TypKind.UNEXPOSED
        # try to resolve Unexposed type to cursor definition.
        rtdef_cu = cindex.getTypeDeclaration(rt)
        if (!is_null(rtdef_cu) && !isa(rtdef_cu, NoDeclFound))
            return cu_type(rtdef_cu)
        end
    end
    # otherwise, this will either be a builtin or unexposed
    # client needs to sort out.
    return rt
end

function return_type(c::CXNode, resolve::Bool)
    if (!is_function(c))
        error("return_type Cursor argument must be a function")
    end
    if (resolve)
        return resolve_type( getCursorResultType(c) )
    else
        return getCursorResultType(c)
    end
end
return_type(c::CXNode) = return_type(c, true)

function value(c::CXNode)
    if !isa(c, EnumConstantDecl)
        error("Not a value cursor.")
    end
    t = cu_type(c)
    if anymatch(ty_kind(t), 
        TypKind.INT, TypKind.LONG, TypKind.LONGLONG)
            return getEnumConstantDeclValue(c)
    end
    if anymatch(ty_kind(t),
        TypKind.UINT, TypKind.ULONG, TypKind.ULONGLONG)
            return getEnumConstantDeclUnsignedValue(c)
    end
end

tu_init(hdrfile::Any) = tu_init(hdrfile, 0, false, 0)
function tu_init(hdrfile::Any, diagnostics, cpp::Bool, opts::Int)
    idx = idx_create(0,diagnostics)
    tu = tu_parse(idx, hdrfile, (cpp ? ["-x", "c++"] : [""]), opts)
    return tu
end

###############################################################################
# Utility functions

tu_dispose(tu::CXTranslationUnit) = ccall( (:clang_disposeTranslationUnit, "libclang"), Void, (Ptr{Void},), tu)

function tu_cursor(tu::CXTranslationUnit)
    if (tu == C_NULL)
        error("Invalid TranslationUnit!")
    end
    getTranslationUnitCursor(tu)
end
 
tu_parse(CXIndex, source_filename::ASCIIString, 
                 cl_args::Array{ASCIIString,1}, num_clargs,
                 unsaved_files::CXUnsavedFile, num_unsaved_files,
                 options) =
    ccall( (:clang_parseTranslationUnit, "libclang"),
        CXTranslationUnit,
        (Ptr{Void}, Ptr{Uint8}, Ptr{Ptr{Uint8}}, Uint32, Ptr{Void}, Uint32, Uint32), 
            CXIndex, source_filename,
            cl_args, num_clargs,
            unsaved_files, num_unsaved_files, options)

idx_create() = idx_create(0,0)
idx_create(excludeDeclsFromPCH::Int, displayDiagnostics::Int) =
    ccall( (:clang_createIndex, "libclang"),
        CXTranslationUnit,
        (Int32, Int32),
        excludeDeclsFromPCH, displayDiagnostics)

#Typedef{"Pointer CXFile"} clang_getFile(CXTranslationUnit, const char *)
getFile(tu::CXTranslationUnit, file::ASCIIString) = 
    ccall( (:clang_getFile, "libclang"),
        CXFile,
        (Ptr{Void}, Ptr{Uint8}), tu, file)

function cl_create()
    cl = CursorList(C_NULL,0)
    cl.ptr = ccall( (:wci_createCursorList, libwci),
        Ptr{Void},
        () )
    return cl
end

function cl_dispose(cl::CursorList)
    ccall( (:wci_disposeCursorList, libwci),
        None,
        (Ptr{Void},), cl.ptr)
    cl.ptr = C_NULL
    cl.size = 0
end

cl_size(cl::CursorList) = cl.size
cl_size(clptr::Ptr{Void}) =
    ccall( (:wci_sizeofCursorList, libwci),
        Int,
        (Ptr{Void},), clptr)

function getindex(cl::CursorList, clid::Int, default::UnionType)
    try
        getindex(cl, clid)
    catch
        return default
    end
end
function getindex(cl::CursorList, clid::Int)
    if (clid < 1 || clid > cl.size) error("Index out of range or empty list") end 
    cu = TmpCursor()
    ccall( (:wci_getCLCursor, libwci),
        Void,
        (Ptr{Void}, Ptr{Void}, Int), cu.data, cl.ptr, clid-1)
    return CXCursor(cu)
end

function children(cu::CXNode)
    cl = cl_create() 
    ccall( (:wci_getChildren, libwci),
        Ptr{Void},
            (Ptr{CXCursor}, Ptr{Void}), cu.data, cl.ptr)
    cl.size = cl_size(cl.ptr)
    return cl
end

function cu_file(cu::CXNode)
    str = CXString()
    ccall( (:wci_getCursorFile, libwci),
        Void,
            (Ptr{Void}, Ptr{Void}), cu.data, str.data)
    return get_string(str)
end

start(cl::CursorList) = 1
done(cl::CursorList, i) = (i == cl.size)
next(cl::CursorList, i) = (cl[i], i+1)

end # module
