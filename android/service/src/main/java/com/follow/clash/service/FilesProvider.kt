package com.follow.clash.service

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException

class FilesProvider : DocumentsProvider() {

    companion object {
        private const val DEFAULT_ROOT_ID = "0"

        private val DEFAULT_DOCUMENT_COLUMNS = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_FLAGS,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        private val DEFAULT_ROOT_COLUMNS = arrayOf(
            DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_FLAGS,
            DocumentsContract.Root.COLUMN_ICON,
            DocumentsContract.Root.COLUMN_TITLE,
            DocumentsContract.Root.COLUMN_SUMMARY,
            DocumentsContract.Root.COLUMN_DOCUMENT_ID
        )
    }

    private val baseDir: File
        get() = context?.filesDir ?: throw IllegalStateException("Context not available")

    /**
     * Resolve a documentId (relative path) to an actual File,
     * ensuring it stays within baseDir to prevent path traversal.
     */
    private fun resolveFile(documentId: String): File {
        val file = if (documentId == "/") {
            baseDir
        } else {
            File(baseDir, documentId)
        }
        val canonical = file.canonicalFile
        val baseDirCanonical = baseDir.canonicalFile
        if (!canonical.path.startsWith(baseDirCanonical.path)) {
            throw SecurityException("Access denied: path traversal detected")
        }
        return canonical
    }

    /**
     * Convert a File to a documentId (path relative to baseDir).
     */
    private fun fileToDocumentId(file: File): String {
        val relativePath = file.canonicalPath.removePrefix(baseDir.canonicalPath)
        return if (relativePath.isEmpty()) "/" else relativePath
    }

    override fun onCreate(): Boolean {
        return true
    }

    override fun queryRoots(projection: Array<String>?): Cursor {
        return MatrixCursor(projection ?: DEFAULT_ROOT_COLUMNS).apply {
            newRow().apply {
                add(DocumentsContract.Root.COLUMN_ROOT_ID, DEFAULT_ROOT_ID)
                add(DocumentsContract.Root.COLUMN_FLAGS, DocumentsContract.Root.FLAG_LOCAL_ONLY)
                add(DocumentsContract.Root.COLUMN_ICON, R.drawable.ic_service)
                add(DocumentsContract.Root.COLUMN_TITLE, "FlClash")
                add(DocumentsContract.Root.COLUMN_SUMMARY, "Data")
                add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, "/")
            }
        }
    }


    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<String>?,
        sortOrder: String?
    ): Cursor {
        val result = MatrixCursor(resolveDocumentProjection(projection))
        val parentFile = resolveFile(parentDocumentId)
        if (!parentFile.isDirectory) throw FileNotFoundException("Not a directory")
        parentFile.listFiles()?.forEach { file ->
            includeFile(result, file)
        }
        return result
    }

    override fun queryDocument(documentId: String, projection: Array<String>?): Cursor {
        val result = MatrixCursor(resolveDocumentProjection(projection))
        val file = resolveFile(documentId)
        includeFile(result, file)
        return result
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        val file = resolveFile(documentId)
        if (!file.exists()) throw FileNotFoundException("File not found: $documentId")
        val accessMode = ParcelFileDescriptor.parseMode(mode)
        return ParcelFileDescriptor.open(file, accessMode)
    }

    private fun includeFile(result: MatrixCursor, file: File) {
        result.newRow().apply {
            add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, fileToDocumentId(file))
            add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, file.name)
            add(DocumentsContract.Document.COLUMN_SIZE, file.length())
            add(
                DocumentsContract.Document.COLUMN_FLAGS,
                DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
            )
            add(DocumentsContract.Document.COLUMN_MIME_TYPE, getDocumentType(file))
        }
    }

    private fun getDocumentType(file: File): String {
        return if (file.isDirectory) {
            DocumentsContract.Document.MIME_TYPE_DIR
        } else {
            "application/octet-stream"
        }
    }

    private fun resolveDocumentProjection(projection: Array<String>?): Array<String> {
        return projection ?: DEFAULT_DOCUMENT_COLUMNS
    }
}