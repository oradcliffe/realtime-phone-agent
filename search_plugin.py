"""
Search plugin for Azure AI Search integration.

This is an original file created to extend the Call Automation demo
with Azure AI Search capabilities.
"""

from azure.search.documents import SearchClient
from azure.core.credentials import AzureKeyCredential
import os
import logging
from semantic_kernel.functions import kernel_function

class SearchPlugin:
    """Plugin for querying Azure AI Search."""
    
    def __init__(self):
        self.logger = logging.getLogger("search_plugin")
        self.search_endpoint = os.environ.get("AZURE_SEARCH_ENDPOINT")
        self.search_key = os.environ.get("AZURE_SEARCH_KEY")
        self.search_index = os.environ.get("AZURE_SEARCH_INDEX", "products")
        
        if self.search_endpoint and self.search_key:
            self.credential = AzureKeyCredential(self.search_key)
            self.search_client = SearchClient(
                endpoint=self.search_endpoint,
                index_name=self.search_index,
                credential=self.credential
            )
            self.logger.info(f"Initialized Azure AI Search client for index {self.search_index}")
        else:
            self.search_client = None
            self.logger.warning("Azure AI Search credentials not provided")
    
    @kernel_function
    def search_products(self, query: str, top: int = 3) -> str:
        """
        Search for products matching the query.
        
        Args:
            query: The search query
            top: Maximum number of results to return
            
        Returns:
            Formatted string with search results
        """
        if not self.search_client:
            return "I'm sorry, but I can't search our product catalog at the moment."
        
        self.logger.info(f"Searching for products with query: {query}")
        
        try:
            # Use semantic search if available, otherwise fall back to keyword search
            try:
                # Check if semantic search is available
                results = self.search_client.search(
                    query,
                    top=top,
                    query_type="semantic",
                    semantic_configuration_name="default",
                    query_caption="extractive",
                    query_answer="extractive"
                )
            except Exception:
                # Fall back to regular search
                self.logger.info("Falling back to regular search")
                results = self.search_client.search(query, top=top)
            
            # Convert results to a list for processing
            result_list = list(results)
            
            if not result_list:
                return f"I couldn't find any products matching '{query}'. Would you like information about our most popular products instead?"
            
            # Format results into a natural language response
            response = f"Here's what I found about '{query}':\n\n"
            
            for i, result in enumerate(result_list, 1):
                response += f"{i}. {result.get('name', 'Product')}: {result.get('description', 'No description available')} "
                if 'price' in result:
                    response += f"Price: ${float(result['price']):.2f}. "
                if 'features' in result and result['features']:
                    features = ", ".join(result['features'][:3])
                    response += f"Key features include {features}."
                response += "\n\n"
            
            return response
        
        except Exception as e:
            self.logger.error(f"Error searching products: {str(e)}")
            return "I'm having trouble searching our product catalog. Can you please try a different question?"